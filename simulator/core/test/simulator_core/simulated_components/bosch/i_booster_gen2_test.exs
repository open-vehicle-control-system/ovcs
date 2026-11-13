defmodule SimulatorCore.SimulatedComponents.Bosch.IBoosterGen2Test do
  use ExUnit.Case, async: true

  import SimulatorCore.CanFrames, only: [read_back: 3, signals: 1]

  alias SimulatorCore.SimulatedComponents.Bosch.IBoosterGen2
  alias SimulatorCore.Vehicle

  @emitted_status "can/components/bosch/i_booster_gen2/simulated/0x39D_ibooster_status.yml"
  @shared_status "can/components/bosch/i_booster_gen2/0x39D_ibooster_status.yml"
  @vehicle Vehicle.new(%{wheelbase_m: 2.46, wheel_radius_m: 0.3})
  # The VMS's flow rates: its zero point, and the most it commands either side of it.
  @zero_point_flow_rate 0x7E00
  @flow_rate_range 0x1400
  @full_flow_rate @zero_point_flow_rate + @flow_rate_range

  setup do
    {state, received, emitted} =
      IBoosterGen2.init(
        network: :misc,
        controller: "front_controller",
        power_relay_pin: 5,
        rod_speed_mm_s: 20.0,
        full_travel_deceleration_m_s2: 8.0
      )

    %{state: state, received: received, emitted: emitted}
  end

  defp power(state, on?) do
    request = signals(%{"digital_pin5_enabled" => on?})
    IBoosterGen2.handle_frame("front_controller_digital_pin_request", request, state, 0)
  end

  defp brake_request(state, external_request, flow_rate) do
    request = signals(%{"external_request" => external_request, "flow_rate" => flow_rate})
    IBoosterGen2.handle_frame("brake_request", request, state, 0)
  end

  # The status reported at `now_ms`, as the VMS decodes it.
  defp status(state, now_ms) do
    {state, [{:misc, "ibooster_status", status}]} = IBoosterGen2.report(state, @vehicle, now_ms)
    {state, read_back(status, @emitted_status, @shared_status)}
  end

  defp rod_position_mm(status), do: Decimal.to_float(status["rod_position"])

  defp deceleration(state) do
    case IBoosterGen2.actuations(state, @vehicle, 0) do
      [] -> 0.0
      [{:deceleration, m_s2}] -> m_s2
    end
  end

  # Powered, under external request at `flow_rate`, with its first report at 0 ms.
  defp braking(state, flow_rate) do
    {state, _status} = state |> power(true) |> brake_request(true, flow_rate) |> status(0)
    state
  end

  test "reads its controller's pin request and the VMS's brake request", %{received: received} do
    assert Enum.sort(received) == [
             {:misc, "brake_request"},
             {:ovcs, "front_controller_digital_pin_request"}
           ]
  end

  test "starts off, which the VMS reads as the driver braking", %{emitted: emitted} do
    [{:misc, "ibooster_status", status}] = emitted
    status = read_back(status, @emitted_status, @shared_status)

    assert {status["status"], status["driver_brake_apply"]} == {"off", "not_init_or_off"}
  end

  test "reads ready with the brakes not applied and the rod at rest once powered",
       %{state: state} do
    {_state, status} = state |> power(true) |> status(0)

    assert {status["status"], status["driver_brake_apply"]} == {"ready", "brakes_not_applied"}
    assert_in_delta rod_position_mm(status), 0.0, 0.02
  end

  test "reads off again once its power relay drops", %{state: state} do
    {_state, status} = state |> power(true) |> power(false) |> status(0)

    assert status["status"] == "off"
  end

  test "pushes the rod as fast as the flow rate asks, and brakes in proportion to its travel",
       %{state: state} do
    {state, status} = state |> braking(@full_flow_rate) |> status(250)

    assert_in_delta rod_position_mm(status), 5.0, 0.02
    assert_in_delta deceleration(state), 5.0 / 16.56 * 8.0, 1.0e-6
  end

  test "holds the rod at the zero point's flow rate", %{state: state} do
    {state, _status} = state |> braking(@full_flow_rate) |> status(250)

    {_state, status} = state |> brake_request(true, @zero_point_flow_rate) |> status(1_000)

    assert_in_delta rod_position_mm(status), 5.0, 0.02
  end

  test "springs the rod back without an external request", %{state: state} do
    {state, _status} = state |> braking(@full_flow_rate) |> status(250)

    {state, status} = state |> brake_request(false, @zero_point_flow_rate) |> status(1_000)

    assert_in_delta rod_position_mm(status), 0.0, 0.02
    assert deceleration(state) == 0.0
  end

  test "keeps the rod within its travel", %{state: state} do
    {state, status} = state |> braking(@full_flow_rate) |> status(10_000)

    assert_in_delta rod_position_mm(status), 16.56, 0.02
    assert_in_delta deceleration(state), 8.0, 1.0e-6
  end

  test "does not move the rod unpowered", %{state: state} do
    {state, _status} = state |> brake_request(true, @full_flow_rate) |> status(0)

    {state, status} = status(state, 500)

    assert_in_delta rod_position_mm(status), 0.0, 0.02
    assert deceleration(state) == 0.0
  end
end
