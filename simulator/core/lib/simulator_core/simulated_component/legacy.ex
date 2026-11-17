defmodule SimulatorCore.SimulatedComponent.Legacy do
  @moduledoc """
  Runs a simulated component that still acts through `actuations/3` and
  reports through `report/3` on the efforts loop, until it implements
  `efforts/3` and `measure/3`. Pure.

  Its accelerations and decelerations become torques through the
  vehicle's mass and wheel radius, and its steering the front wheels'
  angle. It measures the wheels' mean speed and their turns since the
  previous tick, the motion its `report/3` reads.
  """

  alias SimulatorCore.{Efforts, WorldState}

  @typedoc "What an old simulated component reads of the vehicle's motion."
  @type motion :: %{
          measured_speed_m_s: float(),
          wheel_turns_step: float(),
          wheel_radius_m: float()
        }

  @typedoc "An old simulated component's actuation."
  @type actuation :: {:acceleration, float()} | {:deceleration, float()} | {:steering, float()}

  @doc """
  The motion `world` shows an old simulated component, from the wheels'
  mean angle at the previous tick, with the wheels' mean angle now; no
  turns before a previous angle.
  """
  @spec motion(WorldState.t(), float() | nil) :: {motion(), float()}
  def motion(world, previous_angle_rad) do
    wheels = WorldState.mean(world, WorldState.wheels())
    turned_rad = wheels.angle_rad - (previous_angle_rad || wheels.angle_rad)

    {%{
       measured_speed_m_s: wheels.omega_rad_s * world.wheel_radius_m,
       wheel_turns_step: turned_rad / (2 * :math.pi()),
       wheel_radius_m: world.wheel_radius_m
     }, wheels.angle_rad}
  end

  @doc "The efforts an old simulated component's actuations ask of a vehicle of `mass_kg`."
  @spec efforts([actuation()], float(), float()) :: [Efforts.actuation()]
  def efforts(actuations, mass_kg, wheel_radius_m) do
    Enum.map(actuations, fn
      {:acceleration, m_s2} -> {:drive_torque_nm, m_s2 * mass_kg * wheel_radius_m}
      {:deceleration, m_s2} -> {:brake_torque_nm, abs(m_s2) * mass_kg * wheel_radius_m}
      {:steering, rad} -> {:steering_rad, rad}
    end)
  end
end
