defmodule SimulatorCore.FlatGroundTest do
  use ExUnit.Case, async: true

  alias SimulatorCore.{Efforts, FlatGround}

  doctest FlatGround

  @dt 0.02

  defp ground(overrides \\ %{}) do
    FlatGround.new(Map.merge(%{wheelbase_m: 0.3, wheel_radius_m: 0.5, mass_kg: 100.0}, overrides))
  end

  defp run(ground, efforts, seconds) do
    Enum.reduce(1..round(seconds / @dt), ground, fn _, g -> FlatGround.step(g, efforts, @dt) end)
  end

  describe "step/3" do
    test "a drive torque accelerates the mass and the driveline" do
      efforts = %Efforts{drive_torque_nm: 100.0, driveline_inertia_kg_m2: 25.0}

      assert_in_delta FlatGround.step(ground(), efforts, 0.1).speed_m_s, 0.1, 1.0e-12
    end

    test "at rest, a drive under the rolling resistance does not move it" do
      resisting = ground(%{rolling_deceleration_m_s2: 0.5})

      assert run(resisting, %Efforts{drive_torque_nm: 20.0}, 1.0).speed_m_s == 0.0
    end

    test "a drive past the rolling resistance accelerates by the difference" do
      resisting = ground(%{rolling_deceleration_m_s2: 0.5})

      assert_in_delta FlatGround.step(resisting, %Efforts{drive_torque_nm: 50.0}, 0.1).speed_m_s,
                      0.05,
                      1.0e-12
    end

    test "a brake above the drive holds the car at standstill" do
      held = run(ground(), %Efforts{drive_torque_nm: 50.0, brake_torque_nm: 60.0}, 1.0)

      assert held.speed_m_s == 0.0
      assert held.x_m == 0.0
    end

    test "a brake stops the car at zero, even over a long step" do
      rolling = %{ground() | speed_m_s: 1.0}
      braking = %Efforts{brake_torque_nm: 500.0}

      stopped = FlatGround.step(rolling, braking, 1.0)
      assert stopped.speed_m_s == 0.0
      assert_in_delta stopped.x_m, 0.05, 1.0e-12

      assert FlatGround.step(stopped, braking, 1.0).speed_m_s == 0.0
    end

    test "rolling resistance alone stops a coasting car in reverse without turning it forward" do
      coasting = %{ground(%{rolling_deceleration_m_s2: 1.0}) | speed_m_s: -0.5}

      assert run(coasting, %Efforts{}, 1.0).speed_m_s == 0.0
    end

    test "the last steering is the front wheels' angle" do
      assert FlatGround.step(ground(), %Efforts{steering_rad: 0.2}, @dt).steering_rad == 0.2
    end
  end

  describe "world_state/1" do
    test "every wheel turns with the speed, on the ground" do
      moving = FlatGround.step(%{ground() | speed_m_s: 1.0}, %Efforts{}, 0.5)
      world = FlatGround.world_state(moving)

      for wheel <- [:front_left, :front_right, :rear_left, :rear_right] do
        assert_in_delta world.wheels[wheel].angle_rad, 1.0, 1.0e-12
        assert_in_delta world.wheels[wheel].omega_rad_s, 2.0, 1.0e-12
        assert world.wheels[wheel].in_contact
      end

      assert world.wheel_radius_m == 0.5
      assert world.linear_velocity_m_s == {1.0, 0.0, 0.0}
    end

    test "the body's acceleration is the step's change of speed" do
      accelerating = FlatGround.step(ground(), %Efforts{drive_torque_nm: 100.0}, 0.1)

      {forward, sideways, vertical} =
        FlatGround.world_state(accelerating).linear_acceleration_m_s2

      assert_in_delta forward, 2.0, 1.0e-12
      assert {sideways, vertical} == {0.0, 0.0}
    end
  end

  describe "pose" do
    # Steering that turns the 0.3 m wheelbase on a 1 m radius.
    @unit_radius_steering :math.atan(0.3)

    defp pose(ground), do: {ground.x_m, ground.y_m, ground.yaw_rad}

    defp assert_pose(ground, {x, y, yaw}) do
      assert_in_delta ground.x_m, x, 1.0e-6
      assert_in_delta ground.y_m, y, 1.0e-6
      assert_in_delta ground.yaw_rad, yaw, 1.0e-6
    end

    defp at_speed(speed_m_s, steering_rad),
      do: %{ground() | speed_m_s: speed_m_s * 1.0, steering_rad: steering_rad}

    defp steer(steering_rad), do: %Efforts{steering_rad: steering_rad}

    test "a car starts at the origin, pointing along x" do
      assert pose(ground()) == {0.0, 0.0, 0.0}
    end

    for {name, speed, steering, {x, y, yaw}} <- [
          {"straight ahead", 1.0, 0.0, {2.0, 0.0, 0.0}},
          {"straight in reverse", -0.5, 0.0, {-1.0, 0.0, 0.0}},
          {"at standstill with the wheels turned", 0.0, @unit_radius_steering, {0.0, 0.0, 0.0}}
        ] do
      test "rolling #{name}, it moves and turns as a bicycle on its rear axle" do
        moved = run(at_speed(unquote(speed), unquote(steering)), steer(unquote(steering)), 2.0)

        assert_pose(moved, {unquote(x), unquote(y), unquote(yaw)})
      end
    end

    test "its curvature is the inverse of its turning radius, positive to the left" do
      assert_in_delta FlatGround.curvature(at_speed(0.0, @unit_radius_steering)), 1.0, 1.0e-9
      assert_in_delta FlatGround.curvature(at_speed(0.0, -@unit_radius_steering)), -1.0, 1.0e-9
    end

    test "a curvature too small to turn the yaw within a step still moves along the yaw" do
      pointing = %{at_speed(1.0 / @dt, 1.0e-18) | yaw_rad: 1.0}

      assert_pose(
        FlatGround.step(pointing, steer(1.0e-18), @dt),
        {:math.cos(1.0), :math.sin(1.0), 1.0}
      )
    end

    for {direction, distance_m, pose} <- [
          {"forward", :math.pi() / 2, {1.0, 1.0, :math.pi() / 2}},
          {"in reverse", -:math.pi() / 2, {-1.0, 1.0, -:math.pi() / 2}}
        ] do
      test "a quarter circle #{direction} in one step lands on the arc's end" do
        rolling = at_speed(unquote(distance_m) / @dt, @unit_radius_steering)

        assert_pose(
          FlatGround.step(rolling, steer(@unit_radius_steering), @dt),
          unquote(Macro.escape(pose))
        )
      end
    end

    test "a full circle at constant steering comes back to the start" do
      lap =
        Enum.reduce(1..100, at_speed(2 * :math.pi() / 100 / @dt, @unit_radius_steering), fn _,
                                                                                            g ->
          FlatGround.step(g, steer(@unit_radius_steering), @dt)
        end)

      assert_pose(lap, {0.0, 0.0, 0.0})
    end
  end
end
