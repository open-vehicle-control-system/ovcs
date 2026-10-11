defmodule RosBridge.Simulator.VehicleTest do
  use ExUnit.Case, async: true

  alias RosBridge.Simulator.Vehicle

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
    assert run(vehicle(), [{:acceleration, 0.9}], 1.0).speed_m_s == 0.0
  end

  test "a drive past the rolling resistance accelerates by the difference" do
    assert_in_delta run(vehicle(), [{:acceleration, 2.0}], 1.0).speed_m_s, 1.0, 0.02
  end

  test "rolling resistance alone stops a coasting vehicle without reversing it" do
    stopped = run(vehicle(%{speed_m_s: 0.5}), [], 1.0)
    assert stopped.speed_m_s == 0.0
  end

  test "a brake stops the vehicle without reversing it" do
    assert run(vehicle(%{speed_m_s: -0.5}), [{:deceleration, 5.0}], 1.0).speed_m_s == 0.0
  end

  test "the speed stays within the maximum" do
    assert run(vehicle(), [{:acceleration, 50.0}], 1.0).speed_m_s == 3.0
  end

  test "wheel turns follow the distance rolled" do
    rolled = run(vehicle(%{rolling_deceleration_m_s2: 0.0, speed_m_s: 1.0}), [], 1.0)
    assert_in_delta rolled.wheel_turns, 1.0 / (2 * :math.pi() * 0.05), 0.01
  end

  test "a simulator at half real time reads half the speed on the wall clock" do
    cruising = vehicle(%{rolling_deceleration_m_s2: 0.0, speed_m_s: 1.0})

    observed =
      Enum.reduce(1..100, cruising, fn _, v -> Vehicle.step(v, [], @dt / 2, wall_dt_s: @dt) end)

    assert observed.speed_m_s == 1.0
    assert_in_delta observed.wall_speed_m_s, 0.5, 0.01
  end

  test "a stopped vehicle reads exactly zero on the wall clock" do
    stopping = vehicle(%{speed_m_s: 0.01, wall_speed_m_s: 0.3})
    assert Vehicle.step(stopping, [{:deceleration, 10.0}], @dt).wall_speed_m_s == 0.0
  end

  test "a vehicle the simulator holds still rolls nowhere, however hard it is driven" do
    held =
      Enum.reduce(1..100, vehicle(), fn _, v ->
        Vehicle.step(v, [{:acceleration, 3.0}], @dt, measured_speed_m_s: 0.0)
      end)

    assert held.speed_m_s > 0.0 and held.speed_m_s <= 0.25
    assert held.measured_speed_m_s == 0.0
    assert held.wheel_turns == 0.0
    assert held.wall_speed_m_s == 0.0
  end

  test "the distance follows the measured speed, not the commanded one" do
    rolled =
      Enum.reduce(1..100, vehicle(%{rolling_deceleration_m_s2: 0.0}), fn _, v ->
        Vehicle.step(v, [{:acceleration, 1.0}], @dt, measured_speed_m_s: 0.25)
      end)

    assert_in_delta rolled.wheel_turns, 0.25 / (2 * :math.pi() * 0.05), 0.001
  end

  test "physics jitter at rest measures as standstill" do
    resting = Vehicle.step(vehicle(), [], @dt, measured_speed_m_s: 0.002)
    assert resting.measured_speed_m_s == 0.0
  end

  test "the yaw rate is Ackermann's, positive to the left" do
    turning = %{vehicle() | speed_m_s: 1.0, steering_rad: 0.3}
    assert_in_delta Vehicle.yaw_rate(turning), :math.tan(0.3) / 0.3, 1.0e-9
  end
end
