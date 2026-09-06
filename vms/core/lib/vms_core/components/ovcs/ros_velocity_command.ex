defmodule VmsCore.Components.OVCS.RosVelocityCommand do
  @moduledoc """
  Turns a velocity command into steering and throttle.

  The second command path into the VMS. `RosActuatorCommand.*` carries
  normalised axes — what a joystick means; this carries linear and
  angular velocity on `ros_velocity_command` (`0x2B1`) — what a planner
  means.

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

  Negative `linear` is reverse. The actuator command carries a separate
  `direction` because on OVCS1 a negative throttle means regenerative
  braking; a velocity has its sign built in.

  ## Staleness

  The frame's `sequence` increments once per ROS sample, and
  `RosCommand.Freshness` zeroes the velocity when it has not changed
  for `@timeout_ms`, whether the planner stopped publishing, the bridge
  died or the CAN link was cut. A retransmitted frame is not applied as
  fresh input, so a stray frame after an outage cannot re-poison the
  request. The timeout is tighter than the joystick's: a planner
  publishes on its own control period (Nav2's `controller_frequency` is
  20 Hz in the simulator) and nobody is watching the vehicle when it
  stops.

  ## Options

    * `:wheelbase`, `:steering_limit` — from the vehicle's
      `geometry/0`, in metres and radians.
    * `:max_speed` — m/s at full throttle. Not geometry: it is a
      property of the motor and gearing, not a dimension.
    * `:steering_sign` — `1` or `-1`, default `1`. REP-103 makes a
      positive yaw rate a left turn; whether a positive
      `requested_steering` turns this vehicle's servo left is a fact
      about the servo and its linkage. The joystick path settles the
      same question with the sign of its scale. Measure it on the
      servo before the first ROS drive and set it here.
  """
  use GenServer

  alias Cantastic.{Frame, Receiver, Signal}
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.RosCommand.Freshness

  require Logger

  @loop_period 10
  @timeout_ms 300
  @zero D.new(0)
  @frame_name "ros_velocity_command"
  # Below this the linear velocity is exactly zero as far as the wire
  # can say (its resolution is 0.01), and the steering angle is undefined.
  @standstill_m_s 0.01

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{wheelbase: wheelbase, steering_limit: steering_limit, max_speed: max_speed} = args) do
    steering_sign = Map.get(args, :steering_sign, 1)

    unless steering_sign in [1, -1] do
      raise ArgumentError, "steering_sign must be 1 or -1, got #{inspect(steering_sign)}"
    end

    :ok = Receiver.subscribe(self(), :ovcs, @frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       geometry: %{wheelbase: wheelbase, steering_limit: steering_limit},
       max_speed: max_speed,
       steering_sign: steering_sign,
       freshness: Freshness.new(@timeout_ms, now()),
       linear: @zero,
       angular: @zero,
       requested_steering: @zero,
       requested_throttle: @zero
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    {transition, freshness} = Freshness.check(state.freshness, now())

    state =
      %{state | freshness: freshness}
      |> apply_transition(transition)
      |> compute()
      |> emit()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: @frame_name, signals: signals}}, state) do
    %{
      "linear" => %Signal{value: linear},
      "angular" => %Signal{value: angular},
      "sequence" => %Signal{value: sequence}
    } = signals

    case Freshness.observe(state.freshness, sequence, now()) do
      {:new, freshness} ->
        {:noreply, %{state | freshness: freshness, linear: linear, angular: angular}}

      {:repeat, freshness} ->
        {:noreply, %{state | freshness: freshness}}
    end
  end

  # A stray message must not kill the drive path.
  def handle_info(_message, state), do: {:noreply, state}

  defp apply_transition(state, :stale) do
    Logger.warning(
      "#{__MODULE__}: #{@frame_name} carries no new sample — velocity zeroed. " <>
        "Nothing is commanding this vehicle."
    )

    %{state | linear: @zero, angular: @zero}
  end

  defp apply_transition(state, :fresh) do
    Logger.info("#{__MODULE__}: #{@frame_name} is fresh again")
    state
  end

  defp apply_transition(state, :unchanged), do: state

  defp compute(state) do
    linear = D.to_float(state.linear)
    angular = D.to_float(state.angular)

    %{
      state
      | requested_steering:
          steering(linear, angular, state.geometry) |> D.mult(state.steering_sign),
        requested_throttle: throttle(linear, state.max_speed)
    }
  end

  # Clamp the yaw rate first: at a standstill the achievable rate is
  # zero, so the whole impossible case collapses to "straight ahead"
  # without a branch of its own.
  defp steering(linear, angular, geometry) do
    limit = OvcsVehicle.max_yaw_rate(geometry, linear)
    clamped = angular |> max(-limit) |> min(limit)

    # This guard only exists for a linear of exactly zero (or `-0.0`,
    # which does not match a `+0.0` pattern from OTP 27 on), where the
    # division below is undefined. The yaw clamp above already bounds
    # the angle to the steering limit at any non-zero speed, so the
    # smallest value the wire can carry commands full lock at near-zero
    # throttle, which is the Ackermann answer rather than a
    # discontinuity.
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

  defp now, do: System.monotonic_time(:millisecond)
end
