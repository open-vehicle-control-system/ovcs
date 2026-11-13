defmodule SimulatorCore.Vehicle do
  @moduledoc """
  The simulated vehicle's motion, as `SimulatorCore.Hardware`'s
  simulated components see it: a commanded speed along its yaw, a
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

  Each `step/4` produces the four motion fields the rest of the tick
  uses:

    * `commanded_speed_m_s` and `steering_rad` — what the simulator is
      asked for;
    * `measured_speed_m_s` — how fast the wheels turned, for the
      simulated components' rates;
    * `wheel_turns_step` — how far they turned in the step, for their
      counters.

  The wheel turns are the world's measurement when `step/4` is given
  one, the command otherwise. The measured speed is the step's
  distance smoothed over `@speed_time_constant_s`, by a filter whose
  output integrates back to the distance; under `@standstill_m_s` it is
  zero, so physics jitter at rest does not keep the VMS's standstill
  gate shut through the rates, while the counters follow the wheels as
  they are.

  The commanded speed is at most `@command_lead_m_s` faster than the
  measured one in its own direction, so it cannot wind up against an
  obstacle, and within `:max_speed_m_s`. The measurement only ever
  lowers it: wheel samples that arrive in a burst read as a speed
  spike, which must not drive the vehicle.

  Speeds are per wall second, the clock the VMS measures against, and
  `dt_s` is the step's length in wall seconds.

  ## Pose

  Each step also moves the vehicle's pose, in REP-103 axes from where
  it started: `x_m` forward, `y_m` to the left, and `yaw_rad`
  counter-clockwise from x, within ±π. The pose is the rear axle's
  centre, moved as a kinematic bicycle: the step's distance, the wheel
  turns times the circumference, signed as they are, runs along the
  arc of `curvature/1`, so a constant steering traces an exact circle
  whatever the step's length.

  ## Examples

  The OVCS Mini's geometry, a 20 ms step, starting at 0.30 m/s:

      iex> alias SimulatorCore.Vehicle
      iex> circumference = 2 * :math.pi() * 0.0522
      iex> cruising = %{Vehicle.new(%{wheelbase_m: 0.324, wheel_radius_m: 0.0522}) |
      ...>   commanded_speed_m_s: 0.3, measured_speed_m_s: 0.3}
      iex> # Asked for more while rolling 6 mm: the setpoint, within the lead.
      iex> faster = Vehicle.step(cruising, [{:speed, 0.4}, {:steering, 0.2}], 0.02, 0.006 / circumference)
      iex> {faster.commanded_speed_m_s, Float.round(faster.measured_speed_m_s, 3), faster.steering_rad}
      {0.4, 0.3, 0.2}
      iex> # A burst of late samples, 15 cm in one step: the rate spikes, the command stays.
      iex> burst = Vehicle.step(cruising, [{:speed, 0.0}], 0.02, 0.15 / circumference)
      iex> {burst.commanded_speed_m_s, Float.round(burst.measured_speed_m_s, 3)}
      {0.0, 1.5}

  Held against a wall, the wheels do not turn and the command stops at
  the lead:

      iex> alias SimulatorCore.Vehicle
      iex> stalled = Vehicle.new(%{wheelbase_m: 0.324, wheel_radius_m: 0.0522})
      iex> Vehicle.step(stalled, [{:speed, 1.0}], 0.02, 0.0).commanded_speed_m_s
      0.25

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
    wheel_turns_step: 0.0,
    x_m: 0.0,
    y_m: 0.0,
    yaw_rad: 0.0
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

          commanded = commanded |> lead_limited(measured) |> clamp(vehicle.max_speed_m_s)
          {commanded, measured, wheel_turns_step}
      end

    %{
      vehicle
      | commanded_speed_m_s: commanded,
        measured_speed_m_s: measured,
        steering_rad: steering,
        wheel_turns_step: wheel_turns_step
    }
    |> moved(wheel_turns_step * circumference(vehicle))
  end

  @doc "The curvature, 1/m, positive to the left, its steering sets on its rear axle's path."
  def curvature(vehicle), do: :math.tan(vehicle.steering_rad) / vehicle.wheelbase_m

  defp circumference(vehicle), do: 2 * :math.pi() * vehicle.wheel_radius_m

  # Along the arc's chord, which points halfway through the yaw change.
  defp moved(vehicle, distance_m) do
    yaw_change = distance_m * curvature(vehicle)
    chord_m = distance_m * sinc(yaw_change / 2)
    chord_yaw = vehicle.yaw_rad + yaw_change / 2
    yaw = vehicle.yaw_rad + yaw_change

    %{
      vehicle
      | x_m: vehicle.x_m + chord_m * :math.cos(chord_yaw),
        y_m: vehicle.y_m + chord_m * :math.sin(chord_yaw),
        yaw_rad: :math.atan2(:math.sin(yaw), :math.cos(yaw))
    }
  end

  defp sinc(angle) when angle == 0.0, do: 1.0
  defp sinc(angle), do: :math.sin(angle) / angle

  defp lead_limited(speed, measured) when speed >= 0,
    do: min(speed, max(measured, 0.0) + @command_lead_m_s)

  defp lead_limited(speed, measured), do: max(speed, min(measured, 0.0) - @command_lead_m_s)

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
