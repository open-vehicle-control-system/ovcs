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

  test "physics jitter at rest measures as standstill" do
    resting = Vehicle.step(%{vehicle() | measured_speed_m_s: 0.002}, [], @dt, 0.0)
    assert resting.measured_speed_m_s == 0.0
  end

  test "the yaw rate is Ackermann's, positive to the left" do
    turning = %{vehicle() | commanded_speed_m_s: 1.0, steering_rad: 0.3}
    assert_in_delta Vehicle.yaw_rate(turning), :math.tan(0.3) / 0.3, 1.0e-9
  end
end
