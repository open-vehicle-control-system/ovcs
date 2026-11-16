defmodule SimulatorCore.FlatGround do
  @moduledoc """
  A world for when no external simulator owns the vehicle's dynamics:
  one rigid body on four wheels that never slip, on flat ground. Pure. It is lower fidelity than an external
  world: no wheel lifts, slides or spins in the air, and nothing stands
  in the vehicle's way.

  Each step takes the tick's `SimulatorCore.Efforts`. The drive torque
  pushes the body through the wheel radius, against the mass plus the
  driveline's inertia seen at the wheels; the brake torque and the
  vehicle's `:rolling_deceleration_m_s2` resist the motion. At rest
  they hold the vehicle until the drive exceeds them; in motion they
  stop it at zero, never reversing it, however long the step.

  The pose is the rear axle's centre, in REP-103 axes from where the
  vehicle started: `x_m` forward, `y_m` to the left, and `yaw_rad`
  counter-clockwise from x, within ±π. It moves as a kinematic bicycle:
  the step's distance runs along the arc of `curvature/1`, so a
  constant steering traces an exact circle whatever the step's length.

  ## Examples

  A 100 kg vehicle on 0.5 m wheels, driven by 100 N m for 0.1 s:

      iex> alias SimulatorCore.{Efforts, FlatGround}
      iex> ground = FlatGround.new(%{wheelbase_m: 2.0, wheel_radius_m: 0.5, mass_kg: 100.0})
      iex> FlatGround.step(ground, %Efforts{drive_torque_nm: 100.0}, 0.1).speed_m_s
      0.2
  """

  alias SimulatorCore.{Efforts, WorldState}

  @enforce_keys [:wheelbase_m, :wheel_radius_m, :mass_kg]
  defstruct [
    :wheelbase_m,
    :wheel_radius_m,
    :mass_kg,
    rolling_deceleration_m_s2: 0.0,
    speed_m_s: 0.0,
    acceleration_m_s2: 0.0,
    steering_rad: 0.0,
    wheel_angle_rad: 0.0,
    x_m: 0.0,
    y_m: 0.0,
    yaw_rad: 0.0
  ]

  @type t :: %__MODULE__{}

  @doc "A vehicle at rest at the origin."
  @spec new(map()) :: t()
  def new(parameters), do: struct!(__MODULE__, parameters)

  @doc "Advances the vehicle by `dt_s` under `efforts`."
  @spec step(t(), Efforts.t(), float()) :: t()
  def step(ground, efforts, dt_s) do
    {speed, distance_m} = next_speed(ground, efforts, dt_s)

    %{
      ground
      | speed_m_s: speed,
        acceleration_m_s2: if(dt_s > 0, do: (speed - ground.speed_m_s) / dt_s, else: 0.0),
        steering_rad: efforts.steering_rad,
        wheel_angle_rad: ground.wheel_angle_rad + distance_m / ground.wheel_radius_m
    }
    |> moved(distance_m)
  end

  @doc "What the vehicle's wheels and body report, as an external world would."
  @spec world_state(t()) :: WorldState.t()
  def world_state(ground) do
    wheel = %{
      angle_rad: ground.wheel_angle_rad,
      omega_rad_s: ground.speed_m_s / ground.wheel_radius_m,
      in_contact: true
    }

    yaw_rate = ground.speed_m_s * curvature(ground)

    %WorldState{
      wheel_radius_m: ground.wheel_radius_m,
      wheels: Map.new(WorldState.wheels(), &{&1, wheel}),
      position_m: {ground.x_m, ground.y_m, 0.0},
      yaw_rad: ground.yaw_rad,
      linear_velocity_m_s: {ground.speed_m_s, 0.0, 0.0},
      angular_velocity_rad_s: {0.0, 0.0, yaw_rate},
      linear_acceleration_m_s2: {ground.acceleration_m_s2, ground.speed_m_s * yaw_rate, 0.0}
    }
  end

  @doc "The curvature, 1/m, positive to the left, its steering sets on its rear axle's path."
  @spec curvature(t()) :: float()
  def curvature(ground), do: :math.tan(ground.steering_rad) / ground.wheelbase_m

  # The speed after the step and the distance covered in it.
  defp next_speed(ground, efforts, dt_s) do
    radius = ground.wheel_radius_m
    effective_mass = ground.mass_kg + efforts.driveline_inertia_kg_m2 / (radius * radius)
    drive_n = efforts.drive_torque_nm / radius

    resisting_n =
      efforts.brake_torque_nm / radius + ground.mass_kg * ground.rolling_deceleration_m_s2

    speed = ground.speed_m_s

    cond do
      speed == 0.0 and abs(drive_n) <= resisting_n ->
        {0.0, 0.0}

      speed == 0.0 ->
        acceleration = (drive_n - sign(drive_n) * resisting_n) / effective_mass
        {acceleration * dt_s, acceleration * dt_s * dt_s / 2}

      true ->
        acceleration = (drive_n - sign(speed) * resisting_n) / effective_mass
        next = speed + acceleration * dt_s

        # Stops at zero on the way through; the next step starts from rest.
        if sign(next) != sign(speed) or next == 0.0,
          do: {0.0, speed * abs(speed / acceleration) / 2},
          else: {next, (speed + next) / 2 * dt_s}
    end
  end

  # Along the arc's chord, which points halfway through the yaw change.
  defp moved(ground, distance_m) do
    yaw_change = distance_m * curvature(ground)
    chord_m = distance_m * sinc(yaw_change / 2)
    chord_yaw = ground.yaw_rad + yaw_change / 2
    yaw = ground.yaw_rad + yaw_change

    %{
      ground
      | x_m: ground.x_m + chord_m * :math.cos(chord_yaw),
        y_m: ground.y_m + chord_m * :math.sin(chord_yaw),
        yaw_rad: :math.atan2(:math.sin(yaw), :math.cos(yaw))
    }
  end

  defp sinc(angle) when angle == 0.0, do: 1.0
  defp sinc(angle), do: :math.sin(angle) / angle

  defp sign(value) when value < 0, do: -1.0
  defp sign(_value), do: 1.0
end
