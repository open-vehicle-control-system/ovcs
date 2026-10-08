defmodule RosBridge.Consumers.Joy.State do
  defstruct [
    :watchdog,
    :active,
    profiles: %{},
    ignored: MapSet.new(),
    released: MapSet.new(),
    direction: "forward",
    sequence: 0
  ]
end

defmodule RosBridge.Consumers.Joy do
  @moduledoc """
  Subscribes to ROS 2 `sensor_msgs/Joy` topics via the native-Zenoh
  client (`RosBridge.ZenohClient.subscribe/2`) and translates each
  sample into the `ros_actuator_command` frame (`0x2B0`): the
  operator's axes as normalised positions.

  ## Profiles

  Each controller has its own layout, described by a profile file
  (`RosBridge.Consumers.Joy.Profile`) that reads `joy/<name>`; the
  operator's `joy` node picks the topic from the controller plugged in.
  The framework ships one profile per supported controller in this
  application's `priv/joy`; `:profiles_dir` names a vehicle's own
  directory, whose profiles add to them, one of the same name replacing
  the framework's.

  One controller commands at a time: the first to publish keeps the
  vehicle until its input goes stale, and another publishing meanwhile
  is ignored, with a warning. Going stale also forgets which pedals
  were seen released, since a restarted `joy` node reports them as 0
  again, and the direction returns to forward.

  ## Why the axis conversion is defensive

  This is the drive path: steering and throttle are each a signed
  16-bit signal at a resolution of 0.001. Two things a joystick can
  legally send would otherwise go wrong here, and neither announces
  itself.

  **An axis outside [-1, 1] would wrap on the wire.** Cantastic encodes
  a signed field by truncation rather than raising, so an out-of-range
  value comes back out with the wrong sign. `joy-linux` normally
  normalises to [-1, 1], but a device whose reported range disagrees
  with its actual travel, or a calibration offset, can exceed it.

  **A short `axes` array would crash the consumer.** `Enum.at/2`
  answers `nil` past the end and `Decimal.from_float/1` has no clause
  for it, and `sensor_msgs/Joy` explicitly permits empty `axes`.

  So `Profile.command/3` clamps, and a missing axis reads as centre
  rather than as a crash. Centre is the safe reading: it commands
  neither steering nor throttle.

  ## The sequence

  Every sample increments the frame's `sequence`. `Cantastic.Emitter`
  retransmits the frame at its period whether or not a new sample was
  written, so the sequence is the only thing on the bus that says
  whether the input is live; the VMS components zero the throttle when
  it stops changing.

  ## The joystick going away is not the same as the bridge going away

  `Cantastic.Emitter` keeps its data in state and retransmits on a
  timer, so once a throttle has been written the frames keep leaving
  at 100 Hz whether or not anything is still feeding them. Unplug the
  controller, kill the `joy` node, partition Zenoh — the CAN bus looks
  healthy and carries a command nobody is issuing.

  The VMS-side `Cantastic.ReceivedFrameWatcher` cannot see that,
  because from its side nothing is wrong. So this consumer watches its
  own input and zeroes the throttle when it stops arriving. See
  `RosBridge.InputWatchdog` for the two hops and what each covers.

  The default timeout is 500 ms, against samples that arrive every
  50 ms: the base station runs `joy_linux` with
  `autorepeat_rate` at 20 Hz, so a still controller still publishes.
  Lower that rate and this has to rise with it.

  Only the throttle is zeroed. Steering holds, for the same reason it
  holds in `VmsCore.Components.OVCS.RosActuatorCommand.Throttle`:
  removing propulsion is what makes the vehicle safe, while snapping
  the wheels straight mid-corner is a new hazard rather than a
  mitigation.
  """
  alias Cantastic.Emitter
  alias Decimal, as: D
  alias Ros2.SensorMsgs.Msg.Joy
  alias RosBridge.Consumers.Joy.{Profile, State}
  alias RosBridge.InputWatchdog

  require Logger
  use GenServer

  @frame_name "ros_actuator_command"
  # Ten missed samples at the 20 Hz autorepeat rate. At 2 m/s that is
  # about a metre of travel — longer than the VMS-side watcher's 50 ms,
  # because this has to tolerate a scheduling hiccup on the operator's
  # machine and a hop across the Zenoh fabric.
  @default_timeout_ms 500
  @check_period_ms 50

  @impl true
  def init(opts) do
    :ok =
      Emitter.configure(:ovcs, @frame_name, %{
        parameters_builder_function: :default,
        initial_data: %{
          "steering" => D.new(0),
          "throttle" => D.new(0),
          "direction" => "forward",
          "sequence" => 0
        },
        enable: true
      })

    vehicle_profiles =
      case Keyword.get(opts, :profiles_dir) do
        nil -> []
        dir -> Profile.load_dir!(dir)
      end

    profiles =
      (Profile.load_dir!(Profile.framework_dir()) ++ vehicle_profiles)
      |> Map.new(&{&1.name, &1})
      |> Map.new(fn {_name, profile} -> {Profile.topic(profile), profile} end)

    Logger.info("#{__MODULE__} profiles on #{profiles |> Map.keys() |> Enum.join(", ")}")

    for topic <- Map.keys(profiles), do: :ok = RosBridge.ZenohClient.subscribe(topic, Joy)
    {:ok, _timer} = :timer.send_interval(@check_period_ms, :check_input)

    {:ok, %State{watchdog: InputWatchdog.new(timeout_ms()), profiles: profiles}}
  end

  defp timeout_ms do
    Application.get_env(:ros_bridge, :joy_timeout_ms, @default_timeout_ms)
  end

  defp topics(state), do: state.profiles |> Map.keys() |> Enum.join(" or ")

  @spec start_link(keyword()) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc """
  The throttle and the frame's direction for the gear lever's
  `requested` direction, `last` being the direction sent before. In
  neutral the throttle only brakes and the direction holds; a profile
  without `gears` (`nil`) drives forward.
  """
  def gear(nil, throttle, _last), do: {throttle, "forward"}
  def gear(:neutral, throttle, last), do: {min(throttle, 0.0), last}
  def gear(requested, throttle, _last), do: {throttle, Atom.to_string(requested)}

  # `from_float/1` has no integer clause; the profile's sums are floats.
  defp decimal(value), do: value |> Kernel.*(1.0) |> D.from_float()

  @impl true
  def handle_info({:ros_message, {key_expr, %Joy{} = joy}}, state) do
    profile = Map.fetch!(state.profiles, topic(key_expr))

    if state.active in [nil, profile.name],
      do: {:noreply, drive(profile, joy, state)},
      else: {:noreply, ignore(profile, state)}
  end

  # The transition, not the state, so this logs once per outage rather
  # than twenty times a second.
  def handle_info(:check_input, state) do
    {transition, watchdog} = InputWatchdog.check(state.watchdog)
    state = handle_transition(transition, %{state | watchdog: watchdog})
    {:noreply, state}
  end

  # Anything else delivered as `{:ros_message, …}` is a configuration
  # bug (wrong subscribe call somewhere): log loudly rather than
  # silently dropping or matching on the wrong shape.
  def handle_info({:ros_message, {key_expr, message}}, state) do
    Logger.warning("#{__MODULE__} unexpected message on #{key_expr}: #{inspect(message)}")

    {:noreply, state}
  end

  defp drive(profile, %Joy{axes: axes, buttons: buttons}, state) do
    {steering, throttle, released} = Profile.command(profile, axes, state.released)

    {throttle, direction} =
      gear(Profile.direction(profile, axes, buttons), throttle, state.direction)

    sequence = next_sequence(state.sequence)

    :ok =
      Emitter.update(:ovcs, @frame_name, fn data ->
        %{
          data
          | "steering" => decimal(steering),
            "throttle" => decimal(throttle),
            "direction" => direction,
            "sequence" => sequence
        }
      end)

    %{
      state
      | watchdog: InputWatchdog.seen(state.watchdog),
        active: profile.name,
        released: released,
        direction: direction,
        sequence: sequence
    }
  end

  # Once per controller and outage, not twenty times a second.
  defp ignore(profile, state) do
    unless MapSet.member?(state.ignored, profile.name) do
      Logger.warning(
        "#{__MODULE__}: ignoring #{Profile.topic(profile)}, #{state.active} is commanding the vehicle"
      )
    end

    %{state | ignored: MapSet.put(state.ignored, profile.name)}
  end

  # Nothing has ever arrived, which is a setup problem rather than a
  # loss: the topic name, the domain id, or a `joy` node that was never
  # started. Said once, on the first tick, because nothing downstream
  # can tell -- the emitter keeps sending valid zeroed frames, so the
  # VMS-side watcher sees a perfectly healthy stream.
  defp handle_transition(:silent, state) do
    Logger.warning(
      "#{__MODULE__}: nothing has published #{topics(state)} since start. " <>
        "Check the topic name and ROS_DOMAIN_ID; the controller is not " <>
        "commanding this vehicle."
    )

    zero_throttle(state)
  end

  defp handle_transition(:stale, state) do
    Logger.warning(
      "#{__MODULE__}: no #{topics(state)} sample for #{timeout_ms()} ms — throttle zeroed. " <>
        "The controller is not commanding this vehicle."
    )

    zero_throttle(state)
  end

  defp handle_transition(:fresh, state) do
    Logger.info("#{__MODULE__}: #{state.active} is commanding the vehicle")
    state
  end

  defp handle_transition(:unchanged, state), do: state

  # Steering is left alone deliberately — see the moduledoc. The zero is
  # a new sample as far as the VMS is concerned, so it gets a sequence.
  defp zero_throttle(state) do
    sequence = next_sequence(state.sequence)

    :ok =
      Emitter.update(:ovcs, @frame_name, fn data ->
        %{data | "throttle" => D.new(0), "sequence" => sequence}
      end)

    %{
      state
      | sequence: sequence,
        active: nil,
        ignored: MapSet.new(),
        released: MapSet.new(),
        direction: "forward"
    }
  end

  @doc false
  def next_sequence(sequence), do: rem(sequence + 1, 256)

  @doc "The topic of an rmw_zenoh key: `<domain>/<topic>/<type>/<hash>`."
  def topic(key_expr) do
    key_expr |> String.split("/") |> Enum.slice(1..-3//1) |> Enum.join("/")
  end
end
