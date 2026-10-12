defmodule RosBridge.Simulator.Vehicle do
  @moduledoc """
  The simulated vehicle's motion, as `RosBridge.Simulator.Hardware`'s
  simulated components see it: a commanded speed along the heading, a
  steering angle, and how far and how fast the wheels turned.

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
  to start moving.

  ## Commanded and measured

  `commanded_speed_m_s` is the speed handed to the simulator.
  `wheel_turns_step` and `measured_speed_m_s` are how far and how fast
  the wheels turned in the step: the simulator's wheel joints when
  `step/4` is given them, the command otherwise. The measured speed is
  the step's distance smoothed over `@speed_time_constant_s`, by a filter
  whose output integrates back to the distance. The commanded speed stays
  within `@command_lead_m_s` of the measured one, so it cannot wind up
  against an obstacle, and within `:max_speed_m_s`. A measured speed
  under `@standstill_m_s` is zero, so physics jitter at rest does not
  keep the VMS's standstill gate shut through the rates; the counters
  follow the wheels as they are.

  Speeds are per wall second, the clock the VMS measures against, and
  `dt_s` is a step of it.

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
    commanded_speed_m_s: 0.0,
    measured_speed_m_s: 0.0,
    steering_rad: 0.0,
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
    commanded = setpoint || next_speed(vehicle.commanded_speed_m_s, drive, resistance, dt_s)

    {commanded, measured, wheel_turns_step} =
      case wheel_turns_step do
        nil ->
          commanded = clamp(commanded, vehicle.max_speed_m_s)
          {commanded, commanded, commanded * dt_s / circumference(vehicle)}

        wheel_turns_step ->
          measured =
            vehicle.measured_speed_m_s
            |> smoothed(wheel_turns_step * circumference(vehicle), dt_s)
            |> standstill()

          commanded = commanded |> within_lead(measured) |> clamp(vehicle.max_speed_m_s)
          {commanded, measured, wheel_turns_step}
      end

    %{
      vehicle
      | commanded_speed_m_s: commanded,
        measured_speed_m_s: measured,
        steering_rad: steering,
        wheel_turns_step: wheel_turns_step
    }
  end

  @doc "The yaw rate of an Ackermann vehicle at its commanded speed and steering."
  def yaw_rate(vehicle),
    do: vehicle.commanded_speed_m_s * :math.tan(vehicle.steering_rad) / vehicle.wheelbase_m

  defp circumference(vehicle), do: 2 * :math.pi() * vehicle.wheel_radius_m

  defp within_lead(speed, measured),
    do: speed |> max(measured - @command_lead_m_s) |> min(measured + @command_lead_m_s)

  defp clamp(speed, max_speed), do: speed |> max(-max_speed) |> min(max_speed)

  defp smoothed(previous, distance_m, dt_s),
    do: previous + (distance_m - previous * dt_s) / (@speed_time_constant_s + dt_s)

  defp standstill(speed) when abs(speed) < @standstill_m_s, do: 0.0
  defp standstill(speed), do: speed

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
  defp next_speed(speed, drive, resistance, dt_s) do
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
  end

  defp sign(value) when value < 0, do: -1.0
  defp sign(_value), do: 1.0
end
