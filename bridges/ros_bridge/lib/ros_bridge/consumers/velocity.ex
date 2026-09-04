defmodule RosBridge.Consumers.Velocity.State do
  defstruct [:watchdog, :topic]
end

defmodule RosBridge.Consumers.Velocity do
  @moduledoc """
  Subscribes to a velocity-command topic and puts it on CAN as
  `ros2_control` (`0x3A0`).

  The counterpart to `RosBridge.Consumers.Joy`, and deliberately a
  different abstraction. A joystick has axes; a planner has a
  velocity. Forwarding the velocity — rather than converting it to
  steering here — means the kinematics are solved once in the VMS,
  against that vehicle's geometry, and any commander speaks the same
  frame without knowing a wheelbase. See
  `VmsCore.Components.OVCS.Ros2Control.Velocity`.

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
  `__MODULE__` and owns the single `0x3A0` emitter, so declaring two
  `:velocity_interpreter` components gives `Supervisor.init/2` two
  child specs with the same id and the whole bridge refuses to boot.
  Even with distinct names they would overwrite each other's frame and
  each watchdog would zero the other's command. One velocity commander
  per vehicle is the actual design; the switch on channel 5 chooses
  between the *velocity* path and the *joystick* path, not between two
  velocity paths.

  Choosing the wrong one of the two is not loud, which is why
  `ZenohClient` warns about surplus bytes after a successful parse:
  `Twist.parse/1` accepts any body of 48 bytes or more, so a 72-byte
  `TwistStamped` body decodes as plausible nonsense — denormals near
  1.0e-273 — and the vehicle ignores every command while both
  watchdogs report a healthy stream.

  ## Staleness

  `Cantastic.Emitter` retransmits on a timer, so a planner that stops
  publishing leaves its last velocity on the bus for ever. The VMS
  cannot tell — from its side the frames keep arriving on time. So the
  input is watched here as well; see `RosBridge.InputWatchdog` for the
  two hops.

  The default timeout is deliberately tighter than the joystick's
  500 ms. A planner publishes on its own control period — Nav2's
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
  alias Decimal, as: D
  alias Ros2.GeometryMsgs.Msg.{Twist, TwistStamped}
  alias RosBridge.Consumers.Velocity.State
  alias RosBridge.InputWatchdog

  require Logger

  @frame_name "ros2_control"
  @default_topic "cmd_vel"
  @default_timeout_ms 300
  @check_period_ms 50

  def start_link(args) do
    Logger.debug("Starting #{__MODULE__}...")
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    opts = Map.new(opts || %{})
    topic = Map.get(opts, :topic, @default_topic)
    message = Map.get(opts, :message, TwistStamped)
    timeout_ms = Map.get(opts, :timeout_ms, @default_timeout_ms)

    :ok =
      Emitter.configure(:ovcs, @frame_name, %{
        parameters_builder_function: :default,
        initial_data: %{"linear" => D.new(0), "angular" => D.new(0)},
        enable: true
      })

    :ok = RosBridge.ZenohClient.subscribe(topic, message)
    {:ok, _timer} = :timer.send_interval(@check_period_ms, :check_input)

    {:ok, %State{watchdog: InputWatchdog.new(timeout_ms), topic: topic}}
  end

  @impl true
  def handle_info({:ros_message, {_key_expr, %TwistStamped{twist: twist}}}, state) do
    {:noreply, command(twist, state)}
  end

  def handle_info({:ros_message, {_key_expr, %Twist{} = twist}}, state) do
    {:noreply, command(twist, state)}
  end

  def handle_info(:check_input, state) do
    {transition, watchdog} = InputWatchdog.check(state.watchdog)
    :ok = handle_transition(transition, state)
    {:noreply, %{state | watchdog: watchdog}}
  end

  def handle_info({:ros_message, {key_expr, message}}, state) do
    Logger.warning("#{__MODULE__} unexpected message on #{key_expr}: #{inspect(message)}")

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Only linear.x and angular.z. The other four components of a Twist
  # are meaningless for a non-holonomic vehicle, and a commander that
  # sets them is asserting something about this vehicle that is not
  # true — worth saying once rather than discarding in silence.
  defp command(%Twist{linear: linear, angular: angular}, state) do
    warn_if_holonomic(linear, angular)

    :ok =
      Emitter.update(:ovcs, @frame_name, fn data ->
        %{
          data
          | "linear" => D.from_float(linear.x / 1.0),
            "angular" => D.from_float(angular.z / 1.0)
        }
      end)

    %{state | watchdog: InputWatchdog.seen(state.watchdog)}
  end

  defp warn_if_holonomic(linear, angular) do
    if linear.y != 0.0 or linear.z != 0.0 or angular.x != 0.0 or angular.y != 0.0 do
      Logger.warning(
        "#{__MODULE__}: ignoring lateral/vertical velocity " <>
          "(linear.y=#{linear.y} linear.z=#{linear.z} " <>
          "angular.x=#{angular.x} angular.y=#{angular.y}). " <>
          "This vehicle is not holonomic; the commander may be configured " <>
          "for a differential-drive or omni platform."
      )
    end

    :ok
  end

  # Never received anything: a topic typo, the wrong ROS_DOMAIN_ID, or a
  # planner that was never launched. Distinct from `:stale` because the
  # cause is at the keyboard, not on the vehicle, and because nothing
  # else in either hop can report it -- the emitter goes on sending
  # well-formed zero frames, so `Cantastic.ReceivedFrameWatcher` on the
  # VMS side sees nothing wrong.
  defp handle_transition(:silent, state) do
    Logger.warning(
      "#{__MODULE__}: nothing has published #{state.topic} since start. " <>
        "Check the topic name and ROS_DOMAIN_ID; nothing is commanding " <>
        "this vehicle."
    )

    zero_velocity()
  end

  defp handle_transition(:stale, state) do
    Logger.warning(
      "#{__MODULE__}: no #{state.topic} sample within the timeout — velocity zeroed. " <>
        "Nothing is commanding this vehicle."
    )

    zero_velocity()
  end

  defp handle_transition(:fresh, state) do
    Logger.info("#{__MODULE__}: #{state.topic} is publishing")
    :ok
  end

  defp handle_transition(:unchanged, _state), do: :ok

  defp zero_velocity do
    Emitter.update(:ovcs, @frame_name, fn data ->
      %{data | "linear" => D.new(0), "angular" => D.new(0)}
    end)
  end
end
