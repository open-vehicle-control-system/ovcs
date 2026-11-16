defmodule SimulatorCore.WorldState do
  @moduledoc """
  What a simulated world reports of the vehicle it moves, for the
  simulated sensors to measure as the vehicle's own would. Pure.

  Each wheel has its cumulative `angle_rad` and its `omega_rad_s`, both
  positive rolling forward, and whether it is `in_contact` with the
  ground: a wheel can spin without the body moving, or stand still
  while the body slides. The body's `position_m`, `yaw_rad`,
  `linear_velocity_m_s` and `angular_velocity_rad_s` follow REP-103,
  velocities in the vehicle's frame, and `linear_acceleration_m_s2` is
  the body's acceleration in that frame, without gravity.
  """

  @wheels [:front_left, :front_right, :rear_left, :rear_right]
  @zero {0.0, 0.0, 0.0}

  @enforce_keys [:wheel_radius_m, :wheels]
  defstruct [
    :wheel_radius_m,
    :wheels,
    position_m: @zero,
    yaw_rad: 0.0,
    linear_velocity_m_s: @zero,
    angular_velocity_rad_s: @zero,
    linear_acceleration_m_s2: @zero
  ]

  @type wheel :: :front_left | :front_right | :rear_left | :rear_right
  @type wheel_state :: %{angle_rad: float(), omega_rad_s: float(), in_contact: boolean()}
  @type vector :: {float(), float(), float()}
  @type t :: %__MODULE__{
          wheel_radius_m: float(),
          wheels: %{wheel() => wheel_state()},
          position_m: vector(),
          yaw_rad: float(),
          linear_velocity_m_s: vector(),
          angular_velocity_rad_s: vector(),
          linear_acceleration_m_s2: vector()
        }

  @doc "The four wheels, in the order the simulator link names them."
  @spec wheels() :: [wheel()]
  def wheels, do: @wheels

  @doc "A vehicle standing still on its four wheels."
  @spec at_rest(float()) :: t()
  def at_rest(wheel_radius_m) do
    %__MODULE__{
      wheel_radius_m: wheel_radius_m,
      wheels: Map.new(@wheels, &{&1, %{angle_rad: 0.0, omega_rad_s: 0.0, in_contact: true}})
    }
  end

  @doc "The mean angle and spin of `wheels`, as a shaft or a differential driving them sees it."
  @spec mean(t(), [wheel()]) :: %{angle_rad: float(), omega_rad_s: float()}
  def mean(world, wheels) do
    states = Enum.map(wheels, &Map.fetch!(world.wheels, &1))
    count = length(states)

    %{
      angle_rad: Enum.sum_by(states, & &1.angle_rad) / count,
      omega_rad_s: Enum.sum_by(states, & &1.omega_rad_s) / count
    }
  end

  @doc "How fast `wheel`'s tread moves, signed: its spin times the wheel radius."
  @spec wheel_speed_m_s(t(), wheel()) :: float()
  def wheel_speed_m_s(world, wheel),
    do: Map.fetch!(world.wheels, wheel).omega_rad_s * world.wheel_radius_m
end
