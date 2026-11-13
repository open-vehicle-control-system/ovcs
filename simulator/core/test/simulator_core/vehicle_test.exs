defmodule SimulatorCore.VehicleTest do
  use ExUnit.Case, async: true

  alias SimulatorCore.Vehicle

  doctest Vehicle

  @dt 0.01

  defp vehicle(overrides \\ %{}) do
    Vehicle.new(
      Map.merge(
        %{wheelbase_m: 0.3, wheel_radius_m: 0.05, rolling_deceleration_m_s2: 1.0},
        overrides
      )
    )
  end

  defp run(vehicle, actuations, seconds) do
    Enum.reduce(1..round(seconds / @dt), vehicle, fn _, v -> Vehicle.step(v, actuations, @dt) end)
  end

  test "a drive weaker than the rolling resistance does not start the vehicle" do
    assert run(vehicle(), [{:acceleration, 0.9}], 1.0).commanded_speed_m_s == 0.0
  end

  test "a drive past the rolling resistance accelerates by the difference" do
    assert_in_delta run(vehicle(), [{:acceleration, 2.0}], 1.0).commanded_speed_m_s, 1.0, 0.02
  end

  test "rolling resistance alone stops a coasting vehicle without reversing it" do
    stopped = run(vehicle(%{commanded_speed_m_s: 0.5}), [], 1.0)
    assert stopped.commanded_speed_m_s == 0.0
  end

  test "a brake stops the vehicle without reversing it" do
    assert run(vehicle(%{commanded_speed_m_s: -0.5}), [{:deceleration, 5.0}], 1.0).commanded_speed_m_s ==
             0.0
  end

  test "a speed setpoint is the commanded speed, within the maximum" do
    assert Vehicle.step(vehicle(), [{:acceleration, 1.0}, {:speed, -0.4}], @dt).commanded_speed_m_s ==
             -0.4

    assert Vehicle.step(vehicle(), [{:speed, 9.0}], @dt).commanded_speed_m_s == 3.0
  end

  test "the speed stays within the maximum" do
    assert run(vehicle(), [{:acceleration, 50.0}], 1.0).commanded_speed_m_s == 3.0
  end

  test "without a measurement, the wheels turn as commanded" do
    cruising = vehicle(%{rolling_deceleration_m_s2: 0.0, commanded_speed_m_s: 1.0})

    assert_in_delta Vehicle.step(cruising, [], @dt).wheel_turns_step,
                    @dt / (2 * :math.pi() * 0.05),
                    1.0e-9
  end

  test "the commanded speed stays within the maximum while following a faster measurement" do
    pushed = vehicle(%{measured_speed_m_s: 3.5, commanded_speed_m_s: 3.0})
    turns = 3.5 * @dt / (2 * :math.pi() * 0.05)
    assert Vehicle.step(pushed, [{:acceleration, 5.0}], @dt, turns).commanded_speed_m_s == 3.0
  end

  test "a step of zero duration keeps the distance it measured" do
    turns = 0.01 / (2 * :math.pi() * 0.05)
    stepped = Vehicle.step(vehicle(), [], 0.0, turns)
    assert_in_delta stepped.measured_speed_m_s, 0.1, 1.0e-9
  end

  test "without a measurement the commanded speed is the measured one" do
    cruising = vehicle(%{rolling_deceleration_m_s2: 0.0, commanded_speed_m_s: 1.0})
    assert Vehicle.step(cruising, [], @dt).measured_speed_m_s == 1.0
  end

  test "a vehicle the simulator holds still rolls nowhere, however hard it is driven" do
    held =
      Enum.reduce(1..100, vehicle(), fn _, v ->
        Vehicle.step(v, [{:acceleration, 3.0}], @dt, 0.0)
      end)

    assert held.commanded_speed_m_s > 0.0 and held.commanded_speed_m_s <= 0.25
    assert held.measured_speed_m_s == 0.0
    assert held.wheel_turns_step == 0.0
  end

  test "the counters follow the measured turns, not the commanded speed" do
    {rolled, turns} =
      Enum.reduce(1..100, {vehicle(%{rolling_deceleration_m_s2: 0.0}), 0.0}, fn _, {v, turns} ->
        v = Vehicle.step(v, [{:acceleration, 1.0}], @dt, 0.01)
        {v, turns + v.wheel_turns_step}
      end)

    assert_in_delta turns, 1.0, 1.0e-9
    assert_in_delta rolled.measured_speed_m_s, 0.01 * 2 * :math.pi() * 0.05 / @dt, 1.0e-3
  end

  test "rates from uneven measurements integrate back to the distance" do
    # One turn's worth arriving in alternate steps, then nothing.
    steps = List.flatten(List.duplicate([0.02, 0.0], 50)) ++ List.duplicate(0.0, 200)

    {rolled, integrated_m} =
      Enum.reduce(steps, {vehicle(%{rolling_deceleration_m_s2: 0.0}), 0.0}, fn turns, {v, m} ->
        v = Vehicle.step(v, [], @dt, turns)
        {v, m + v.measured_speed_m_s * @dt}
      end)

    assert_in_delta integrated_m, 2 * :math.pi() * 0.05, 0.005
    assert rolled.measured_speed_m_s == 0.0
  end

  test "a burst of wheel samples does not drive the vehicle past its command" do
    # Half a second of travel at 0.3 m/s, delivered in one 20 ms step.
    burst = 0.15 / (2 * :math.pi() * 0.05)
    cruising = %{vehicle() | commanded_speed_m_s: 0.3, measured_speed_m_s: 0.3}
    stepped = Vehicle.step(cruising, [{:speed, 0.0}], @dt, burst)

    assert stepped.measured_speed_m_s > 1.0
    assert stepped.commanded_speed_m_s == 0.0
  end

  test "reversing into an obstacle does not wind up" do
    held = Vehicle.step(vehicle(), [{:speed, -1.0}], @dt, 0.0)
    assert_in_delta held.commanded_speed_m_s, -0.25, 1.0e-9
  end

  test "physics jitter at rest measures as standstill" do
    resting = Vehicle.step(%{vehicle() | measured_speed_m_s: 0.002}, [], @dt, 0.0)
    assert resting.measured_speed_m_s == 0.0
  end

  describe "pose" do
    # Steering that turns the 0.3 m wheelbase on a 1 m radius.
    @unit_radius_steering :math.atan(0.3)

    defp turns(distance_m), do: distance_m / (2 * :math.pi() * 0.05)

    defp pose(vehicle), do: {vehicle.x_m, vehicle.y_m, vehicle.yaw_rad}

    defp assert_pose(vehicle, {x, y, yaw}) do
      assert_in_delta vehicle.x_m, x, 1.0e-6
      assert_in_delta vehicle.y_m, y, 1.0e-6
      assert_in_delta vehicle.yaw_rad, yaw, 1.0e-6
    end

    test "a vehicle starts at the origin, pointing along x" do
      assert pose(vehicle()) == {0.0, 0.0, 0.0}
    end

    for {name, speed, steering, {x, y, yaw}} <- [
          {"straight ahead", 1.0, 0.0, {2.0, 0.0, 0.0}},
          {"straight in reverse", -0.5, 0.0, {-1.0, 0.0, 0.0}},
          {"at standstill with the wheels turned", 0.0, @unit_radius_steering, {0.0, 0.0, 0.0}}
        ] do
      test "commanded #{name}, it moves and turns as a bicycle on its rear axle" do
        moved = run(vehicle(), [{:speed, unquote(speed)}, {:steering, unquote(steering)}], 2.0)

        assert_pose(moved, {unquote(x), unquote(y), unquote(yaw)})
      end
    end

    test "its curvature is the inverse of its turning radius, positive to the left" do
      assert_in_delta Vehicle.curvature(%{vehicle() | steering_rad: @unit_radius_steering}),
                      1.0,
                      1.0e-9

      assert_in_delta Vehicle.curvature(%{vehicle() | steering_rad: -@unit_radius_steering}),
                      -1.0,
                      1.0e-9
    end

    test "a curvature too small to turn the yaw within a step still moves along the yaw" do
      pointing = %{vehicle() | yaw_rad: 1.0}
      stepped = Vehicle.step(pointing, [{:steering, 1.0e-18}], @dt, turns(1.0))

      assert_pose(stepped, {:math.cos(1.0), :math.sin(1.0), 1.0})
    end

    for {direction, distance_m, pose} <- [
          {"forward", :math.pi() / 2, {1.0, 1.0, :math.pi() / 2}},
          {"in reverse", -:math.pi() / 2, {-1.0, 1.0, -:math.pi() / 2}}
        ] do
      test "a quarter circle #{direction} in one step lands on the arc's end" do
        stepped =
          Vehicle.step(
            vehicle(),
            [{:steering, @unit_radius_steering}],
            @dt,
            turns(unquote(distance_m))
          )

        assert_pose(stepped, unquote(Macro.escape(pose)))
      end
    end

    test "a full circle at constant steering comes back to the start" do
      lap =
        Enum.reduce(1..100, vehicle(), fn _, v ->
          Vehicle.step(v, [{:steering, @unit_radius_steering}], @dt, turns(2 * :math.pi() / 100))
        end)

      assert_pose(lap, {0.0, 0.0, 0.0})
    end
  end
end
