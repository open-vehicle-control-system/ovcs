defmodule SimulatorCore.SimulatedComponent.LegacyTest do
  use ExUnit.Case, async: true

  alias SimulatorCore.{Efforts, WorldState}
  alias SimulatorCore.SimulatedComponent.Legacy

  @wheel_radius_m 0.5

  # Every wheel at `omega_rad_s`, having turned `angle_rad`.
  defp world(omega_rad_s, angle_rad) do
    wheel = %{angle_rad: angle_rad, omega_rad_s: omega_rad_s, in_contact: true}
    %{WorldState.at_rest(@wheel_radius_m) | wheels: Map.new(WorldState.wheels(), &{&1, wheel})}
  end

  describe "motion/2" do
    test "the wheels' mean speed, and their turns since the previous angle" do
      {motion, angle_rad} = Legacy.motion(world(4.0, 3 * :math.pi()), :math.pi())

      assert motion.measured_speed_m_s == 2.0
      assert_in_delta motion.wheel_turns_step, 1.0, 1.0e-12
      assert motion.wheel_radius_m == @wheel_radius_m
      assert angle_rad == 3 * :math.pi()
    end

    test "no turns before a previous angle" do
      {motion, _angle_rad} = Legacy.motion(world(4.0, 3 * :math.pi()), nil)

      assert motion.wheel_turns_step == 0.0
    end
  end

  describe "efforts/3" do
    test "an acceleration drives the vehicle's mass through the wheel radius" do
      assert Legacy.efforts([{:acceleration, 2.0}], 100.0, @wheel_radius_m) ==
               [{:drive_torque_nm, 100.0}]
    end

    test "a deceleration brakes it, as a magnitude" do
      assert Legacy.efforts([{:deceleration, -2.0}], 100.0, @wheel_radius_m) ==
               [{:brake_torque_nm, 100.0}]
    end

    test "a steering is the front wheels' angle" do
      assert Legacy.efforts([{:steering, 0.2}], 100.0, @wheel_radius_m) ==
               [{:steering_rad, 0.2}]
    end

    test "combined with the efforts of migrated parts, they move the same vehicle" do
      legacy = Legacy.efforts([{:acceleration, 1.0}, {:steering, 0.1}], 100.0, @wheel_radius_m)
      efforts = Efforts.combine(legacy ++ [{:drive_torque_nm, 10.0}], 0.0)

      assert efforts == %Efforts{drive_torque_nm: 60.0, steering_rad: 0.1}
    end
  end
end
