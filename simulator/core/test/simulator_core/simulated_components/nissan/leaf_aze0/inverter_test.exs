defmodule SimulatorCore.SimulatedComponents.Nissan.LeafAZE0.InverterTest do
  use ExUnit.Case, async: true

  import SimulatorCore.CanFrames, only: [read_back: 2, signals: 1]

  alias SimulatorCore.SimulatedComponents.Nissan.LeafAZE0.Inverter
  alias SimulatorCore.Vehicle

  @inverter_status "can/components/nissan/leaf_aze0/0x1DA_inverter_status.yml"
  @inverter_temperatures "can/components/nissan/leaf_aze0/0x55A_inverter_temperatures.yml"
  @wheel_radius_m 0.3

  @options [
    network: :leaf_drive,
    controller: "rear_controller",
    power_relay_pin: 7,
    main_negative_relay_pin: 3,
    main_positive_relay_pin: 4,
    precharge_relay_pin: 5,
    pack_voltage_v: 360,
    reduction_ratio: 8.0,
    mass_kg: 1_000.0
  ]

  setup do
    {state, received, emitted} = Inverter.init(@options)
    %{state: state, received: received, emitted: emitted}
  end

  defp vehicle(measured_speed_m_s),
    do: %{
      Vehicle.new(%{wheelbase_m: 2.46, wheel_radius_m: @wheel_radius_m})
      | measured_speed_m_s: measured_speed_m_s
    }

  defp relays(state, closed_pins) do
    request = signals(Map.new(closed_pins, &{"digital_pin#{&1}_enabled", true}))
    Inverter.handle_frame("rear_controller_digital_pin_request", request, state, 0)
  end

  defp torque(state, torque_nm) do
    request = signals(%{"requested_torque" => Decimal.new(torque_nm)})
    Inverter.handle_frame("vms_torque_request", request, state, 0)
  end

  defp status(state, measured_speed_m_s \\ 0.0) do
    {_state, updates} = Inverter.report(state, vehicle(measured_speed_m_s), 0)
    {:leaf_drive, "inverter_status", status} = List.keyfind(updates, "inverter_status", 1)
    read_back(status, @inverter_status)
  end

  test "reads its torque request and its controller's pin request", %{received: received} do
    assert {:leaf_drive, "vms_torque_request"} in received
    assert {:ovcs, "rear_controller_digital_pin_request"} in received
  end

  test "the VMS reads its status, idle, from the start", %{emitted: emitted} do
    {:leaf_drive, "inverter_status", status} = List.keyfind(emitted, "inverter_status", 1)

    assert %{"inverter_output_voltage" => 0, "rotations_per_minute" => 0} =
             read_back(status, @inverter_status)
  end

  test "the VMS reads its temperatures at 77 °F, a room's 25 °C", %{emitted: emitted} do
    {:leaf_drive, "inverter_temperatures", temperatures} =
      List.keyfind(emitted, "inverter_temperatures", 1)

    assert %{"motor_temperature" => 77, "inverter_communication_board_temperature" => 77} =
             read_back(temperatures, @inverter_temperatures)
  end

  test "reports the pack voltage once main negative and precharge close", %{state: state} do
    assert status(relays(state, [3]))["inverter_output_voltage"] == 0
    assert status(relays(state, [5]))["inverter_output_voltage"] == 0
    assert status(relays(state, [3, 5]))["inverter_output_voltage"] == 360
  end

  test "keeps the pack voltage once main positive replaces precharge", %{state: state} do
    assert status(relays(state, [3, 4]))["inverter_output_voltage"] == 360
  end

  test "drives the requested torque through its reduction, with power and high voltage",
       %{state: state} do
    assert state |> torque(100) |> relays([7]) |> Inverter.actuations(vehicle(0.0), 0) == []
    assert state |> torque(100) |> relays([3, 4]) |> Inverter.actuations(vehicle(0.0), 0) == []

    [{:acceleration, acceleration}] =
      state |> torque(100) |> relays([3, 4, 7]) |> Inverter.actuations(vehicle(0.0), 0)

    assert_in_delta acceleration, 100 * 8.0 / @wheel_radius_m / 1_000.0, 1.0e-9
  end

  test "the VMS reads the torque it applies, and none while it cannot", %{state: state} do
    driving = state |> torque(50) |> relays([3, 4, 7]) |> status()
    assert Decimal.to_float(driving["effective_torque"]) == 50.0

    unpowered = state |> torque(50) |> relays([3, 4]) |> status()
    assert Decimal.to_float(unpowered["effective_torque"]) == 0.0
  end

  test "the VMS reads the motor's rotation, signed by the direction of travel", %{state: state} do
    motor_rpm = 10.0 / (2 * :math.pi() * @wheel_radius_m) * 60 * 8.0

    assert_in_delta status(state, 10.0)["rotations_per_minute"], motor_rpm, 1
    assert_in_delta status(state, -10.0)["rotations_per_minute"], -motor_rpm, 1
  end
end
