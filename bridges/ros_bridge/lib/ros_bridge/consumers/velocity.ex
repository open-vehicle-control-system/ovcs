defmodule RosBridge.Consumers.Velocity.State do
  @moduledoc false
  defstruct [:watchdog, :topic, holonomic_warned: false, sequence: 0]
end

defmodule RosBridge.Consumers.Velocity do
  @moduledoc """
  Subscribes to a velocity-command topic and puts it on CAN as
  `ros_velocity_command` (`0x2B1`).

  The counterpart to `RosBridge.Consumers.Joy`, and deliberately a
  different abstraction. A joystick has axes; a planner has a
  velocity. Forwarding the velocity — rather than converting it to
  steering here — means the kinematics are solved once in the VMS,
  against that vehicle's geometry, and any commander speaks the same
  frame without knowing a wheelbase. See
  `VmsCore.Components.OVCS.RosVelocityCommand`.

  This is also the whole of the bridge's job in this direction:
  unwrap a ROS message and emit a CAN frame. The VMS never hears about
  ROS, and the bridge never learns any vehicle geometry.

  ## TwistStamped by default

  Nav2 1.5.1 publishes `geometry_msgs/TwistStamped` —
  `nav2_util::TwistPublisher` defaults `enable_stamped_cmd_vel` to
  true. `teleop_twist_joy` publishes plain `Twist`. Either can be
  configured, because they are different commanders rather than a
  version skew to pick a side on.

  **One at a time, though.** This is a singleton: it registers under
  `__MODULE__` and owns the single `0x2B1` emitter, so declaring two
  `:velocity_interpreter` components gives `Supervisor.init/2` two
  child specs with the same id and the whole bridge refuses to boot.
  Even with distinct names they would overwrite each other's frame and
  each watchdog would zero the other's command. One velocity commander
  per vehicle is the actual design; the vehicle's control-level switch
  chooses between the *velocity* path and the *joystick* path, not
  between two velocity paths.

  Choosing the wrong one of the two is not loud, which is why
  `ZenohClient` warns about surplus bytes after a successful parse:
  `Twist.parse/1` accepts any body of 48 bytes or more, so a 72-byte
  `TwistStamped` body decodes as plausible nonsense — denormals near
  1.0e-273 — and the vehicle ignores every command while both
  watchdogs report a healthy stream.

  ## Staleness

  `Cantastic.Emitter` retransmits on a timer, so a planner that stops
  publishing would leave its last velocity on the bus for ever. Every
  sample increments the frame's `sequence`, which is what lets the VMS
  tell a live input from a retransmission. The input is watched here as
  well, to zero the emitted value and to say why; see
  `RosBridge.InputWatchdog`.

  The default timeout is deliberately tighter than the joystick's
  default. A planner publishes on its own control period — Nav2's
  `controller_frequency` is 20 Hz in the simulator — and unlike a
  human on a stick there is nobody watching the vehicle when it stops
  publishing.

  ## Options

    * `:topic` (`"cmd_vel"`) — what to subscribe to.
    * `:message` (`TwistStamped`) — `Twist` for an unstamped publisher.
    * `:timeout_ms` (`300`).
  """
  use GenServer

  alias Cantastic.Emitter
  alias Ros2.GeometryMsgs.Msg.{Twist, TwistStamped}
  alias RosBridge.Consumers.Velocity.State
  alias RosBridge.InputWatchdog

  require Logger

  @frame_name "ros_velocity_command"
  @default_topic "cmd_vel"
  @default_timeout_ms 300
  # Watchdog resolution; well under the timeout.
  @check_period_ms 50
  # 0x2B1's wire range (signed 16-bit at 0.01 / 0.001); Cantastic wraps
  # out-of-range values silently, turning a mis-scaled command into reverse.
  @wire_limits %{"linear" => 327.67, "angular" => 32.767}
  # Keeps a mis-scaled commander's warning visible without flooding the log.
  @wire_warning_period_ms 5_000
  # Below this a lateral or vertical component is float noise, not a
  # commander asserting the vehicle is holonomic.
  @holonomic_epsilon 1.0e-6

  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    opts = Map.new(opts || %{})
    topic = Map.get(opts, :topic, @default_topic)
    message_module = Map.get(opts, :message, TwistStamped)
    timeout_ms = Map.get(opts, :timeout_ms, @default_timeout_ms)

    :ok =
      Emitter.configure(:ovcs, @frame_name, %{
        parameters_builder_function: :default,
        initial_data: %{"linear" => Decimal.new(0), "angular" => Decimal.new(0), "sequence" => 0},
        enable: true
      })

    :ok = RosBridge.ZenohClient.subscribe(topic, message_module)
    {:ok, _timer} = :timer.send_interval(@check_period_ms, :check_input)

    {:ok, %State{watchdog: InputWatchdog.new(timeout_ms), topic: topic}}
  end

  @impl GenServer
  def handle_info({:ros_message, {_key_expr, %TwistStamped{twist: twist}}}, state) do
    {:noreply, command(twist, state)}
  end

  def handle_info({:ros_message, {_key_expr, %Twist{} = twist}}, state) do
    {:noreply, command(twist, state)}
  end

  def handle_info(:check_input, state) do
    {transition, watchdog} = InputWatchdog.check(state.watchdog)
    {:noreply, handle_transition(transition, %{state | watchdog: watchdog})}
  end

  def handle_info({:ros_message, {key_expr, message}}, state) do
    Logger.warning("#{__MODULE__} unexpected message on #{key_expr}: #{inspect(message)}")

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Forwards linear.x and angular.z only; the rest trips `warn_if_holonomic/3`.
  defp command(%Twist{linear: linear, angular: angular}, state) do
    state = warn_if_holonomic(linear, angular, state)
    linear_x = wire_value(linear.x / 1.0, "linear")
    angular_z = wire_value(angular.z / 1.0, "angular")
    sequence = next_sequence(state.sequence)

    :ok =
      Emitter.update(:ovcs, @frame_name, fn frame_data ->
        %{
          frame_data
          | "linear" => Decimal.from_float(linear_x),
            "angular" => Decimal.from_float(angular_z),
            "sequence" => sequence
        }
      end)

    %{state | watchdog: InputWatchdog.seen(state.watchdog), sequence: sequence}
  end

  # Once per process: a misconfigured commander sends this on every sample.
  defp warn_if_holonomic(_linear, _angular, %State{holonomic_warned: true} = state), do: state

  defp warn_if_holonomic(linear, angular, state) do
    if abs(linear.y) > @holonomic_epsilon or abs(linear.z) > @holonomic_epsilon or
         abs(angular.x) > @holonomic_epsilon or abs(angular.y) > @holonomic_epsilon do
      Logger.warning(
        "#{__MODULE__}: ignoring lateral/vertical velocity " <>
          "(linear.y=#{linear.y} linear.z=#{linear.z} " <>
          "angular.x=#{angular.x} angular.y=#{angular.y}). " <>
          "This vehicle is not holonomic; the commander may be configured " <>
          "for a differential-drive or omni platform. Reported once."
      )

      %{state | holonomic_warned: true}
    else
      state
    end
  end

  @doc false
  def wire_value(velocity, signal) do
    limit = Map.fetch!(@wire_limits, signal)

    if abs(velocity) <= limit do
      velocity
    else
      warn_wire_limit(velocity, signal, limit)
      velocity |> max(-limit) |> min(limit)
    end
  end

  # Rate-limited per signal: a mis-scaled commander repeats at its own rate.
  defp warn_wire_limit(velocity, signal, limit) do
    now_ms = System.monotonic_time(:millisecond)
    warned_key = {:wire_limit_warned, signal}
    last_warned_at_ms = Process.get(warned_key)

    if is_nil(last_warned_at_ms) or now_ms - last_warned_at_ms >= @wire_warning_period_ms do
      Process.put(warned_key, now_ms)

      Logger.warning(
        "#{__MODULE__}: #{signal}=#{velocity} exceeds what #{@frame_name} can carry " <>
          "(±#{limit}); clamped. No vehicle moves this fast -- check the " <>
          "commander's units."
      )
    end
  end

  # Nothing ever arrived: a setup error neither hop can otherwise report.
  defp handle_transition(:silent, state) do
    Logger.warning(
      "#{__MODULE__}: nothing has published #{state.topic} since start. " <>
        "Check the topic name and ROS_DOMAIN_ID; nothing is commanding " <>
        "this vehicle."
    )

    zero_velocity(state)
  end

  defp handle_transition(:stale, state) do
    Logger.warning(
      "#{__MODULE__}: no #{state.topic} sample within the timeout — velocity zeroed. " <>
        "Nothing is commanding this vehicle."
    )

    zero_velocity(state)
  end

  defp handle_transition(:fresh, state) do
    Logger.info("#{__MODULE__}: #{state.topic} is publishing")
    state
  end

  defp handle_transition(:unchanged, state), do: state

  # A zero is a new sample to the VMS, so it takes a sequence.
  defp zero_velocity(state) do
    sequence = next_sequence(state.sequence)

    :ok =
      Emitter.update(:ovcs, @frame_name, fn frame_data ->
        %{
          frame_data
          | "linear" => Decimal.new(0),
            "angular" => Decimal.new(0),
            "sequence" => sequence
        }
      end)

    %{state | sequence: sequence}
  end

  @doc false
  def next_sequence(sequence), do: rem(sequence + 1, 256)
end
