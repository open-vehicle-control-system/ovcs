defmodule RosBridge.Consumers.Joy.State do
  defstruct [:watchdog, sequence: 0]
end

defmodule RosBridge.Consumers.Joy do
  @moduledoc """
  Subscribes to the ROS 2 `joy` topic via the native-Zenoh client
  (`RosBridge.ZenohClient.subscribe/2`) and translates each
  `sensor_msgs/Joy` sample into the `ros_actuator_command` frame
  (`0x2B0`): the operator's axes as normalised positions.

  ## Why the axis conversion is defensive

  This is the drive path: axis 0 becomes steering and axis 1 throttle,
  each a signed 16-bit signal at a resolution of 0.001. Two things a
  joystick can legally send would otherwise go wrong here, and neither
  announces itself.

  **An axis outside [-1, 1] would wrap on the wire.** Cantastic encodes
  a signed field by truncation rather than raising, so an out-of-range
  value comes back out with the wrong sign. `joy-linux` normally
  normalises to [-1, 1], but a device whose reported range disagrees
  with its actual travel, or a calibration offset, can exceed it.

  **A short `axes` array would crash the consumer.** `Enum.at/2`
  answers `nil` past the end and `Decimal.from_float/1` has no clause
  for it, and `sensor_msgs/Joy` explicitly permits empty `axes`.

  So `control_value/3` clamps, and a missing axis reads as centre
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
  alias RosBridge.Consumers.Joy.State
  alias RosBridge.InputWatchdog

  require Logger
  use GenServer

  @frame_name "ros_actuator_command"
  @joy_topic "joy"
  # Ten missed samples at the 20 Hz autorepeat rate. At 2 m/s that is
  # about a metre of travel — longer than the VMS-side watcher's 50 ms,
  # because this has to tolerate a scheduling hiccup on the operator's
  # machine and a hop across the Zenoh fabric.
  @default_timeout_ms 500
  @check_period_ms 50

  @impl true
  def init(_) do
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

    :ok = RosBridge.ZenohClient.subscribe(@joy_topic, Joy)
    {:ok, _timer} = :timer.send_interval(@check_period_ms, :check_input)

    {:ok, %State{watchdog: InputWatchdog.new(timeout_ms())}}
  end

  defp timeout_ms do
    Application.get_env(:ros_bridge, :joy_timeout_ms, @default_timeout_ms)
  end

  @spec start_link(nil) :: :ignore | {:error, any()} | {:ok, pid()}
  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc """
  One joystick axis as a normalised position in [-1, 1].

  `sign` carries the sign convention: steering is inverted, throttle
  is not. A missing axis, or one that is not a number, reads as centre.
  """
  @spec control_value([number()] | nil, non_neg_integer(), 1 | -1) :: Decimal.t()
  def control_value(axes, index, sign) when is_list(axes) do
    axes
    |> Enum.at(index)
    |> clamp()
    |> D.from_float()
    |> D.mult(sign)
  end

  def control_value(_axes, _index, _sign), do: D.new(0)

  # Centre for anything unusable, rather than raising: the drive path
  # staying up and commanding nothing beats it restarting on every
  # frame. `from_float/1` also has no integer clause, so an axis of `0`
  # rather than `0.0` would raise — hence the float conversion here.
  defp clamp(value) when is_float(value), do: value |> max(-1.0) |> min(1.0)
  defp clamp(value) when is_integer(value), do: clamp(value * 1.0)
  defp clamp(_other), do: 0.0

  @impl true
  def handle_info({:ros_message, {_key_expr, %Joy{axes: axes}}}, state) do
    steering = control_value(axes, 0, -1)
    throttle = control_value(axes, 1, 1)
    sequence = next_sequence(state.sequence)

    :ok =
      Emitter.update(:ovcs, @frame_name, fn data ->
        %{data | "steering" => steering, "throttle" => throttle, "sequence" => sequence}
      end)

    {:noreply, %{state | watchdog: InputWatchdog.seen(state.watchdog), sequence: sequence}}
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

  # Nothing has ever arrived, which is a setup problem rather than a
  # loss: the topic name, the domain id, or a `joy` node that was never
  # started. Said once, on the first tick, because nothing downstream
  # can tell -- the emitter keeps sending valid zeroed frames, so the
  # VMS-side watcher sees a perfectly healthy stream.
  defp handle_transition(:silent, state) do
    Logger.warning(
      "#{__MODULE__}: nothing has published #{@joy_topic} since start. " <>
        "Check the topic name and ROS_DOMAIN_ID; the controller is not " <>
        "commanding this vehicle."
    )

    zero_throttle(state)
  end

  defp handle_transition(:stale, state) do
    Logger.warning(
      "#{__MODULE__}: no #{@joy_topic} sample for #{timeout_ms()} ms — throttle zeroed. " <>
        "The controller is not commanding this vehicle."
    )

    zero_throttle(state)
  end

  defp handle_transition(:fresh, state) do
    Logger.info("#{__MODULE__}: #{@joy_topic} is publishing")
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

    %{state | sequence: sequence}
  end

  @doc false
  def next_sequence(sequence), do: rem(sequence + 1, 256)
end
