defmodule VmsCore.Components.OVCS.Ros2Control.Velocity do
  @moduledoc """
  Turns a velocity command into steering and throttle.

  The second command path into the VMS. `ROSControl.*` carries
  normalised axes — what a joystick means; this carries linear and
  angular velocity on `ros2_control` (`0x3A0`) — what a planner means.

  Solving the kinematics here rather than in each commander means it is
  solved once, against this vehicle's geometry. Nav2, a remote
  operator and a test rig all send the same frame and none of them
  needs to know the wheelbase.

  ## Generic code, vehicle-specific data

  `vms_core` contains no vehicle-specific code, so the geometry arrives
  as options — from the vehicle package's `geometry/0`, which is the
  only place those numbers are declared on the Elixir side.

  ## The conversion

  For an Ackermann vehicle turning at radius `R = v / omega`, the
  steering angle is `atan(wheelbase / R)`, i.e.

      delta = atan(wheelbase * omega / v)

  Clamping happens *before* that, not after, and it is what makes the
  impossible case fall out rather than needing a special case:

      omega <= |v| / min_turning_radius

  At a standstill that bound is zero, so a command to rotate on the
  spot becomes a command to sit still with the wheels straight — which
  is the honest translation, because an Ackermann vehicle cannot
  rotate on the spot and turning the wheels achieves nothing until it
  moves.

  `requested_steering` and `requested_throttle` are then normalised to
  `[-1, 1]` against the steering limit and `:max_speed`, because that
  is the contract the drivetrain components already consume.

  ## Reverse is a sign, not a mode

  Negative `linear` is reverse. `0x2B0` has a separate `direction`
  enum because a joystick axis carries no sign convention of its own;
  a velocity does.

  ## Staleness

  Same hazard as `ROSControl.Throttle`, same remedy:
  `Cantastic.ReceivedFrameWatcher` and `%{errors: true}` on the
  subscription, zeroing on a missing frame. Without it a planner that
  stops publishing leaves its last velocity applied for ever.

  > #### The watcher fires once per alive-episode {: .warning}
  >
  > This does not cover an outage that a stray frame interrupts.
  > `ReceivedFrameWatcher` sends `handle_missing_frame` only on the
  > alive -> dead edge, and the way back requires
  > `!is_alive && !is_late`. Once a sender goes quiet after delivering
  > one frame, `frame_diff` -- the gap between the last two frames
  > received -- stays at the whole outage length, so every tick is late,
  > `!is_alive && is_late` matches no branch, and the handler is never
  > called again. This component's `handle_frame` clause has meanwhile
  > stored that stray frame, so it keeps broadcasting a non-zero
  > throttle and the last computed steering angle at 100 Hz, for the
  > life of the process, with no further warning.
  >
  > The trigger is jitter, not an exotic fault: `0x3A0` declares
  > `frequency: 20` against the fixed `allowed_frequency_leeway`
  > default of 10, so it tolerates 50% inter-frame jitter where every
  > other `ovcs` frame (`frequency: 10`) tolerates 100%. A loaded
  > bridge Pi or a marginal SPI link is enough.
  >
  > Fixing it properly is upstream in `cantastic`. Until then, treat the
  > zeroing here as covering a clean outage only.

  ## Options

    * `:wheelbase`, `:steering_limit` — from the vehicle's
      `geometry/0`, in metres and radians.
    * `:max_speed` — m/s at full throttle. Not geometry: it is a
      property of the motor and gearing, not a dimension.
  """
  use GenServer

  alias Cantastic.{Frame, ReceivedFrameWatcher, Receiver, Signal}
  alias Decimal, as: D
  alias OvcsBus, as: Bus

  require Logger

  @loop_period 10
  @zero D.new(0)
  @frame_name "ros2_control"
  # Below this the vehicle is stopped for every purpose the drivetrain
  # cares about, and the steering angle is undefined. It is also the
  # resolution of the `linear` signal on the wire.
  @standstill_m_s 0.001

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{wheelbase: wheelbase, steering_limit: steering_limit, max_speed: max_speed}) do
    :ok = Receiver.subscribe(self(), :ovcs, @frame_name, %{errors: true})
    :ok = ReceivedFrameWatcher.enable(:ovcs, @frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       geometry: %{wheelbase: wheelbase, steering_limit: steering_limit},
       max_speed: max_speed,
       linear: @zero,
       angular: @zero,
       requested_steering: @zero,
       requested_throttle: @zero
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    {:noreply, state |> compute() |> emit()}
  end

  def handle_info({:handle_frame, %Frame{name: @frame_name, signals: signals}}, state) do
    %{
      "linear" => %Signal{value: linear},
      "angular" => %Signal{value: angular}
    } = signals

    {:noreply, %{state | linear: linear, angular: angular}}
  end

  # Fires once per outage, on the transition to dead.
  def handle_info({:handle_missing_frame, :ovcs, @frame_name}, state) do
    Logger.warning(
      "#{__MODULE__}: #{@frame_name} stopped arriving — velocity zeroed. " <>
        "Nothing is commanding this vehicle."
    )

    {:noreply, %{state | linear: @zero, angular: @zero}}
  end

  # A stray message must not kill the drive path.
  def handle_info(_message, state), do: {:noreply, state}

  defp compute(state) do
    linear = D.to_float(state.linear)
    angular = D.to_float(state.angular)

    %{
      state
      | requested_steering: steering(linear, angular, state.geometry),
        requested_throttle: throttle(linear, state.max_speed)
    }
  end

  # Clamp the yaw rate first: at a standstill the achievable rate is
  # zero, so the whole impossible case collapses to "straight ahead"
  # without a branch of its own.
  defp steering(linear, angular, geometry) do
    limit = OvcsVehicle.max_yaw_rate(geometry, linear)
    clamped = angular |> max(-limit) |> min(limit)

    # A threshold, not `== 0.0`. Two reasons: `-0.0` does not match a
    # `+0.0` pattern from OTP 27 on, and a planner sending 1e-9 m/s
    # would otherwise divide by near-zero and produce a steering angle
    # out of noise. Below a millimetre per second the vehicle is
    # stopped by any measure the drivetrain can act on.
    if abs(linear) < @standstill_m_s do
      @zero
    else
      angle = :math.atan(geometry.wheelbase * clamped / linear)

      (angle / geometry.steering_limit)
      |> max(-1.0)
      |> min(1.0)
      |> D.from_float()
    end
  end

  defp throttle(linear, max_speed) do
    (linear / max_speed)
    |> max(-1.0)
    |> min(1.0)
    |> D.from_float()
  end

  defp emit(state) do
    Bus.broadcast("messages", %Bus.Message{
      name: :requested_steering,
      value: state.requested_steering,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :requested_throttle,
      value: state.requested_throttle,
      source: __MODULE__
    })

    state
  end
end
