defmodule RosBridge.Simulator.Vehicle do
  @moduledoc """
  The simulated vehicle's motion, as `RosBridge.Simulator.Plant`'s
  devices see it: a speed along the heading, a steering angle, and the
  distance rolled.

  Devices act on it through actuations, collected every tick:

    * `{:acceleration, m_s2}` — a drive, signed along the vehicle's
      forward axis: a motor's torque over the vehicle's mass;
    * `{:deceleration, m_s2}` — a brake, a magnitude that opposes the
      motion and stops at standstill rather than reversing;
    * `{:steering, rad}` — the front wheels' angle, REP-103: positive
      turns left.

  Accelerations and decelerations add; the last steering wins. The
  vehicle adds its own `:rolling_deceleration_m_s2`, which a drive must
  overcome to start moving. The speed stays within
  `:max_speed_m_s` either way.

  ## Commanded and measured

  `speed_m_s` is what the drive commands: the speed handed to the
  simulator. `measured_speed_m_s` is the speed the wheels actually
  rolled at, the simulator's when a step is given one, and the
  commanded one otherwise. The commanded speed follows the drive but
  stays within `@command_lead_m_s` of the measured one, enough to cover
  the simulator's reply latency and not enough to wind up against an
  obstacle. The distance, the counters and the rates the devices report
  all follow the measured speed, as the vehicle's wheel and motor
  sensors would. A measurement
  within `@standstill_m_s` of zero is zero, physics jitter at rest that
  would otherwise keep the VMS's standstill gate shut.

  ## Two clocks

  The vehicle moves in simulator time: both speeds are per simulated
  second, and `dt_s` is a simulated step. The VMS measures rates against
  the wall clock, so a device reporting a rate (an rpm, a pulse
  frequency) reports `wall_speed_m_s`: the distance rolled per wall
  second, smoothed over `@wall_speed_time_constant_s`. The two agree
  when the simulator keeps real time. Counters follow the distance,
  `wheel_turns`, and need neither.

  ## Parameters

    * `:wheelbase_m`, `:wheel_radius_m` (required).
    * `:max_speed_m_s` (`3.0`), `:rolling_deceleration_m_s2` (`0.5`).
  """

  @type t :: %__MODULE__{}

  @wall_speed_time_constant_s 0.1
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
    wall_speed_m_s: 0.0,
    steering_rad: 0.0,
    wheel_turns: 0.0,
    wheel_turns_step: 0.0
  ]

  @doc "A vehicle at rest."
  def new(parameters), do: struct!(__MODULE__, parameters)

  @doc """
  Advances the vehicle by `dt_s` of simulator time under `actuations`.

  Options: `:wall_dt_s`, the wall time the step took (`dt_s` when
  omitted), and `:measured_speed_m_s`, the speed the simulator measured
  (the commanded speed when omitted or nil).
  """
  def step(vehicle, actuations, dt_s, opts \\ []) do
    measured = opts |> Keyword.get(:measured_speed_m_s) |> standstill()
    wall_dt_s = Keyword.get(opts, :wall_dt_s) || dt_s
    {drive, brake, steering} = combine(actuations, vehicle.steering_rad)
    resistance = brake + vehicle.rolling_deceleration_m_s2
    speed = next_speed(vehicle.speed_m_s, drive, resistance, dt_s, vehicle.max_speed_m_s)
    speed = if is_nil(measured), do: speed, else: within_lead(speed, measured)
    rolled_at = if is_nil(measured), do: speed, else: measured
    wheel_turns_step = rolled_at * dt_s / (2 * :math.pi() * vehicle.wheel_radius_m)

    %{
      vehicle
      | speed_m_s: speed,
        measured_speed_m_s: rolled_at,
        wall_speed_m_s:
          wall_speed(vehicle.wall_speed_m_s, rolled_at, rolled_at * dt_s, wall_dt_s),
        steering_rad: steering,
        wheel_turns: vehicle.wheel_turns + wheel_turns_step,
        wheel_turns_step: wheel_turns_step
    }
  end

  defp within_lead(speed, measured),
    do: speed |> max(measured - @command_lead_m_s) |> min(measured + @command_lead_m_s)

  defp standstill(nil), do: nil
  defp standstill(speed) when abs(speed) < @standstill_m_s, do: 0.0
  defp standstill(speed), do: speed * 1.0

  # A stopped vehicle reads exactly zero: the VMS's standstill gate waits for it.
  defp wall_speed(_previous, speed, _distance, _wall_dt_s) when speed == 0.0, do: 0.0
  defp wall_speed(previous, _speed, _distance, wall_dt_s) when wall_dt_s <= 0, do: previous

  defp wall_speed(previous, _speed, distance, wall_dt_s) do
    weight = wall_dt_s / (@wall_speed_time_constant_s + wall_dt_s)
    previous + (distance / wall_dt_s - previous) * weight
  end

  defp combine(actuations, steering) do
    Enum.reduce(actuations, {0.0, 0.0, steering}, fn
      {:acceleration, a}, {drive, brake, steering} -> {drive + a, brake, steering}
      {:deceleration, d}, {drive, brake, steering} -> {drive, brake + abs(d), steering}
      {:steering, angle}, {drive, brake, _steering} -> {drive, brake, angle}
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
