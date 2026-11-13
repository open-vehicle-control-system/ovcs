defmodule SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.ABSTest do
  use ExUnit.Case, async: true

  import SimulatorCore.CanFrames, only: [read_back: 2]

  alias SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.ABS
  alias SimulatorCore.Vehicle

  @abs_status "can/components/volkswagen/polo_9n/0x5A0_abs_status.yml"
  @wheels_speed "can/components/volkswagen/polo_9n/0x4A0_wheels_speed.yml"
  @wheels ~w(front_left_wheel_speed front_right_wheel_speed rear_left_wheel_speed rear_right_wheel_speed)

  setup do
    {state, received, emitted} = ABS.init(network: :polo_drive)
    %{state: state, received: received, emitted: emitted}
  end

  defp vehicle(measured_speed_m_s),
    do: %{
      Vehicle.new(%{wheelbase_m: 2.46, wheel_radius_m: 0.296})
      | measured_speed_m_s: measured_speed_m_s
    }

  defp reported(state, measured_speed_m_s) do
    {_state, updates} = ABS.report(state, vehicle(measured_speed_m_s), 0)
    Map.new(updates, fn {:polo_drive, frame, signals} -> {frame, signals} end)
  end

  defp km_h(%Decimal{} = speed), do: Decimal.to_float(speed)

  test "reads nothing and reports standstill from the start", %{
    received: received,
    emitted: emitted
  } do
    assert received == []
    assert {:polo_drive, "abs_status", status} = List.keyfind(emitted, "abs_status", 1)
    assert km_h(read_back(status, @abs_status)["speed"]) == 0.0
    assert List.keymember?(emitted, "wheels_speed", 1)
  end

  test "the VMS reads the measured speed in km/h", %{state: state} do
    status = reported(state, 10.0)["abs_status"]
    assert_in_delta km_h(read_back(status, @abs_status)["speed"]), 36.0, 0.01
  end

  test "the VMS reads every wheel at the measured speed", %{state: state} do
    wheels = read_back(reported(state, 10.0)["wheels_speed"], @wheels_speed)

    for wheel <- @wheels, do: assert_in_delta(km_h(wheels[wheel]), 36.0, 0.01)
  end

  test "reports a speed without its direction, as the unit does", %{state: state} do
    status = reported(state, -2.0)["abs_status"]
    assert_in_delta km_h(read_back(status, @abs_status)["speed"]), 7.2, 0.01
  end
end
