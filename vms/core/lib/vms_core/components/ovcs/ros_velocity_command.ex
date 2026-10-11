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
  `direction` because a negative throttle can mean regenerative
  braking, as on the OVCS1 reference vehicle; a velocity has its sign
  built in.

  ## Staleness

  The frame's `sequence` increments once per ROS sample, and
  `RosCommand.Freshness` zeroes the velocity when it has not changed
  for `@timeout_ms`, whether the planner stopped publishing, the bridge
  died or the CAN link was cut. A retransmitted frame is not applied as
  fresh input, so a stray frame after an outage cannot re-poison the
  request. The timeout is tighter than the joystick's: a planner
  publishes on its own control period (Nav2's `controller_frequency`)
  and nobody is watching the vehicle when it stops.

  ## Options

    * `:wheelbase`, `:steering_limit` — from the vehicle's
      `geometry/0`, in metres and radians.
    * `:max_speed` — m/s at full throttle. Not geometry: it is a
      property of the motor and gearing, not a dimension.
    * `:min_speed` — m/s, default 0. A non-zero linear velocity slower
      than this is driven at it, in its direction: a motor's speed loop
      holds the lowest speeds poorly, and a planner easing in near a
      goal otherwise stops and restarts the vehicle. Zero stays zero.
    * `:steering_sign` — `1` or `-1`, default `1`. REP-103 makes a
      positive yaw rate a left turn; whether a positive
      `requested_steering` turns this vehicle's servo left is a fact
      about the servo and its linkage, found by measuring it on the
      vehicle. The joystick path settles the same question with the
      sign of its scale.
  """
  use GenServer

  alias Cantastic.{Frame, Receiver, Signal}
  alias Decimal, as: D
  alias OvcsBus, as: Bus
  alias VmsCore.Components.OVCS.RosCommand.Freshness

  require Logger

  @loop_period_ms 10
  @timeout_ms 300
  @zero D.new(0)
  @frame_name "ros_velocity_command"
  # Below this the linear velocity is exactly zero as far as the wire
  # can say (its resolution is 0.01), and the steering angle is undefined.
  @standstill_m_s 0.01

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(%{wheelbase: wheelbase, steering_limit: steering_limit, max_speed: max_speed} = args) do
    steering_sign = Map.get(args, :steering_sign, 1)

    unless steering_sign in [1, -1] do
      raise ArgumentError, "steering_sign must be 1 or -1, got #{inspect(steering_sign)}"
    end

    :ok = Receiver.subscribe(self(), :ovcs, @frame_name)
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       loop_timer: timer,
       geometry: %{wheelbase: wheelbase, steering_limit: steering_limit},
       max_speed: max_speed,
       min_speed: Map.get(args, :min_speed, 0.0) * 1.0,
       steering_sign: steering_sign,
       freshness: Freshness.new(@timeout_ms, now_ms()),
       linear: @zero,
       angular: @zero,
       requested_steering: @zero,
       requested_throttle: @zero
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    {transition, freshness} = Freshness.check(state.freshness, now_ms())

    state =
      %{state | freshness: freshness}
      |> apply_transition(transition)
      |> compute_requests()
      |> emit()

    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{name: @frame_name, signals: signals}}, state) do
    %{
      "linear" => %Signal{value: linear},
      "angular" => %Signal{value: angular},
      "sequence" => %Signal{value: sequence}
    } = signals

    case Freshness.observe(state.freshness, sequence, now_ms()) do
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

  defp compute_requests(state) do
    linear_m_s = D.to_float(state.linear)
    angular_rad_s = D.to_float(state.angular)

    %{
      state
      | requested_steering:
          steering(linear_m_s, angular_rad_s, state.geometry) |> D.mult(state.steering_sign),
        requested_throttle: throttle(linear_m_s, state.min_speed, state.max_speed)
    }
  end

  # The yaw clamp collapses rotating on the spot to "straight ahead".
  defp steering(linear_m_s, angular_rad_s, geometry) do
    max_yaw_rate_rad_s = OvcsVehicle.max_yaw_rate(geometry, linear_m_s)
    clamped_angular_rad_s = angular_rad_s |> max(-max_yaw_rate_rad_s) |> min(max_yaw_rate_rad_s)

    # A threshold rather than a `0.0` match, which `-0.0` misses from OTP 27 on.
    # Above it the yaw clamp bounds the angle, so the smallest non-zero linear
    # gives full lock at near-zero throttle rather than a discontinuity.
    if abs(linear_m_s) < @standstill_m_s do
      @zero
    else
      steering_angle_rad = :math.atan(geometry.wheelbase * clamped_angular_rad_s / linear_m_s)

      (steering_angle_rad / geometry.steering_limit)
      |> max(-1.0)
      |> min(1.0)
      |> D.from_float()
    end
  end

  @doc false
  def throttle(linear_m_s, min_speed_m_s, max_speed_m_s) do
    (floor_speed(linear_m_s, min_speed_m_s) / max_speed_m_s)
    |> max(-1.0)
    |> min(1.0)
    |> D.from_float()
  end

  defp floor_speed(linear_m_s, min_speed_m_s)
       when abs(linear_m_s) < @standstill_m_s or abs(linear_m_s) >= min_speed_m_s,
       do: linear_m_s

  defp floor_speed(linear_m_s, min_speed_m_s),
    do: if(linear_m_s > 0, do: min_speed_m_s, else: -min_speed_m_s)

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

  defp now_ms, do: System.monotonic_time(:millisecond)
end
