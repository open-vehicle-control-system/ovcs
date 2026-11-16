defmodule SimulatorCore.WorldStateTest do
  use ExUnit.Case, async: true

  alias SimulatorCore.WorldState

  test "at rest, the four wheels are still and on the ground" do
    world = WorldState.at_rest(0.3)

    assert world.wheel_radius_m == 0.3

    for wheel <- [:front_left, :front_right, :rear_left, :rear_right] do
      assert world.wheels[wheel] == %{angle_rad: 0.0, omega_rad_s: 0.0, in_contact: true}
    end

    assert world.linear_velocity_m_s == {0.0, 0.0, 0.0}
  end

  test "the mean of some wheels averages their angle and spin" do
    world =
      0.3
      |> WorldState.at_rest()
      |> put_wheel(:front_left, 2.0, 4.0)
      |> put_wheel(:front_right, 4.0, 6.0)

    assert WorldState.mean(world, [:front_left, :front_right]) ==
             %{angle_rad: 3.0, omega_rad_s: 5.0}
  end

  test "a wheel's speed is its spin times the radius" do
    world = 0.3 |> WorldState.at_rest() |> put_wheel(:rear_left, 0.0, 10.0)

    assert_in_delta WorldState.wheel_speed_m_s(world, :rear_left), 3.0, 1.0e-12
  end

  defp put_wheel(world, wheel, angle_rad, omega_rad_s),
    do:
      put_in(world.wheels[wheel], %{
        angle_rad: angle_rad,
        omega_rad_s: omega_rad_s,
        in_contact: true
      })
end
