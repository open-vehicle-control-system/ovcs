defmodule RosBridge.Simulator.Vehicle do
  @moduledoc """
  The simulated vehicle's motion, as `RosBridge.Simulator.Plant`'s
  simulated components see it: a speed along the heading, a steering angle, and the
  distance rolled.

  Simulated components act on it through actuations, collected every tick:

    * `{:acceleration, m_s2}` — a drive, signed along the vehicle's
      forward axis: a motor's torque over the vehicle's mass;
    * `{:deceleration, m_s2}` — a brake, a magnitude that opposes the
      motion and stops at standstill rather than reversing;
    * `{:speed, m_s}` — a speed controller's setpoint, signed: the
      commanded speed, which the simulator ramps to;
    * `{:steering, rad}` — the front wheels' angle, REP-103: positive
      turns left.

  Accelerations and decelerations add; the last speed and the last
  steering win, and a speed overrides the accelerations. The vehicle
  adds its own `:rolling_deceleration_m_s2`, which a drive must overcome
  to start moving. The speed stays within `:max_speed_m_s` either way.

  ## Commanded and measured

  `speed_m_s` is what the drive commands: the speed handed to the
  simulator. `wheel_turns` and `measured_speed_m_s` are how far and how
  fast the wheels actually turned: the simulator's when a step is given
  how far they turned, and the commanded motion otherwise. The measured
  speed is that distance per step, smoothed over
  `@speed_time_constant_s`: a linear filter keeps the total, so rates
  integrate back to the counters however unevenly the measurements
  arrive. The
  commanded speed follows the drive but stays within `@command_lead_m_s`
  of the measured one, enough to cover the simulator's reply latency and
  not enough to wind up against an obstacle. The counters and the rates
  the simulated components report follow the measurement, as the
  vehicle's wheel and motor sensors would. A measured speed within
  `@standstill_m_s` of zero is zero, physics jitter at rest that would
  otherwise keep the VMS's standstill gate shut.

  Every speed is per second of the plant's own clock, the wall clock the
  VMS measures rates against, and `dt_s` is a step of it.

  ## Parameters

    * `:wheelbase_m`, `:wheel_radius_m` (required).
    * `:max_speed_m_s` (`3.0`), `:rolling_deceleration_m_s2` (`0.5`).
  """

  @type t :: %__MODULE__{}

  @speed_time_constant_s 0.1
  @standstill_m_s 0.005
  @command_lead_m_s 0.25

  @enforce_keys [:wheelbase_m, :wheel_radius_m]
  defstruct [
    :wheelbase_m,
    :wheel_radius_m,
    max_speed_m_s: 3.0,
    rolling_deceleration_m_s2: 0.5,
    speed_m_s: 0.0,
    measured_speed_m_s: 0.0,
    steering_rad: 0.0,
    wheel_turns: 0.0,
    wheel_turns_step: 0.0
  ]

  @doc "A vehicle at rest."
  def new(parameters), do: struct!(__MODULE__, parameters)

  @doc """
  Advances the vehicle by `dt_s` under `actuations`. `wheel_turns_step`
  is how far the simulator measured the wheels turned in the step, or
  nil to follow the commanded motion.
  """
  def step(vehicle, actuations, dt_s, wheel_turns_step \\ nil) do
    {drive, brake, setpoint, steering} = combine(actuations, vehicle.steering_rad)
    resistance = brake + vehicle.rolling_deceleration_m_s2

    speed =
      if setpoint,
        do: setpoint |> max(-vehicle.max_speed_m_s) |> min(vehicle.max_speed_m_s),
        else: next_speed(vehicle.speed_m_s, drive, resistance, dt_s, vehicle.max_speed_m_s)

    {speed, measured_speed, wheel_turns_step} =
      case wheel_turns_step do
        nil ->
          {speed, speed, speed * dt_s / (2 * :math.pi() * vehicle.wheel_radius_m)}

        wheel_turns_step ->
          distance_m = wheel_turns_step * 2 * :math.pi() * vehicle.wheel_radius_m

          measured_speed =
            vehicle.measured_speed_m_s |> smoothed(distance_m, dt_s) |> standstill()

          {within_lead(speed, measured_speed), measured_speed, wheel_turns_step}
      end

    %{
      vehicle
      | speed_m_s: speed,
        measured_speed_m_s: measured_speed,
        steering_rad: steering,
        wheel_turns: vehicle.wheel_turns + wheel_turns_step,
        wheel_turns_step: wheel_turns_step
    }
  end

  defp within_lead(speed, measured),
    do: speed |> max(measured - @command_lead_m_s) |> min(measured + @command_lead_m_s)

  defp smoothed(previous, _distance_m, dt_s) when dt_s <= 0, do: previous

  defp smoothed(previous, distance_m, dt_s),
    do: previous + (distance_m / dt_s - previous) * dt_s / (@speed_time_constant_s + dt_s)

  defp standstill(speed) when abs(speed) < @standstill_m_s, do: 0.0
  defp standstill(speed), do: speed * 1.0

  defp combine(actuations, steering) do
    Enum.reduce(actuations, {0.0, 0.0, nil, steering}, fn
      {:acceleration, a}, {drive, brake, speed, steering} ->
        {drive + a, brake, speed, steering}

      {:deceleration, d}, {drive, brake, speed, steering} ->
        {drive, brake + abs(d), speed, steering}

      {:speed, s}, {drive, brake, _speed, steering} ->
        {drive, brake, s * 1.0, steering}

      {:steering, angle}, {drive, brake, speed, _steering} ->
        {drive, brake, speed, angle}
    end)
  end

  # At rest, a drive moves the vehicle only past the resistance; in motion, the resistance never reverses it.
  defp next_speed(speed, drive, resistance, dt_s, max_speed) do
    speed =
      cond do
        speed == 0.0 and abs(drive) <= resistance ->
          0.0

        speed == 0.0 ->
          (drive - sign(drive) * resistance) * dt_s

        true ->
          next = sign(speed) * max(abs(speed) - resistance * dt_s, 0.0) + drive * dt_s
          # Stops at zero on the way through; the next step starts from rest.
          if sign(next) != sign(speed) or next == 0.0, do: 0.0, else: next
      end

    speed |> max(-max_speed) |> min(max_speed)
  end

  defp sign(value) when value < 0, do: -1.0
  defp sign(_value), do: 1.0

  @doc "The yaw rate of an Ackermann vehicle at its speed and steering."
  def yaw_rate(vehicle),
    do: vehicle.speed_m_s * :math.tan(vehicle.steering_rad) / vehicle.wheelbase_m
end
