defmodule SimulatorCore.SimulatedComponents.OVCS.SteeringColumnTest do
  use ExUnit.Case, async: true

  import SimulatorCore.CanFrames, only: [read_back: 2, signals: 1]

  alias SimulatorCore.SimulatedComponents.OVCS.SteeringColumn
  alias SimulatorCore.Vehicle

  @lws_status "can/components/bosch/lws/0x2B0_lws_status.yml"
  @vehicle Vehicle.new(%{wheelbase_m: 2.46, wheel_radius_m: 0.3})
  @options [
    network: :misc,
    power_relay_controller: "front_controller",
    power_relay_pin: 6,
    actuation_controller: "controls_controller",
    direction_pin: 1,
    external_pwm_id: 0,
    steps_per_column_degree: 100,
    steering_ratio: 16.0,
    column_limit_deg: 500
  ]

  setup do
    {state, received, emitted} = SteeringColumn.init(@options)
    %{state: state, received: received, emitted: emitted}
  end

  defp frame(state, name, values),
    do: SteeringColumn.handle_frame(name, signals(values), state, 0)

  defp powered(state),
    do: frame(state, "front_controller_digital_pin_request", %{"digital_pin6_enabled" => true})

  defp direction(state, clockwise?),
    do:
      frame(state, "controls_controller_digital_pin_request", %{
        "digital_pin1_enabled" => clockwise?
      })

  # The VMS's PWM request: its frequency is an integer number of steps per second.
  defp stepping(state, frequency_hz, enabled? \\ true),
    do:
      frame(state, "controls_controller_external_pwm0_request", %{
        "enabled" => enabled?,
        "duty_cycle" => 32_768,
        "frequency" => frequency_hz
      })

  # The LWS status the VMS reads after the column turned for `elapsed_ms`.
  defp lws_after(state, elapsed_ms) do
    {state, _updates} = SteeringColumn.report(state, @vehicle, 0)
    {state, [{:misc, "lws_status", status}]} = SteeringColumn.report(state, @vehicle, elapsed_ms)
    {state, read_back(status, @lws_status)}
  end

  defp angle(lws), do: Decimal.to_float(lws["steering_wheel_angle"])

  test "reads its relay, its direction pin and its step PWM", %{received: received} do
    assert Enum.sort(received) == [
             {:ovcs, "controls_controller_digital_pin_request"},
             {:ovcs, "controls_controller_external_pwm0_request"},
             {:ovcs, "front_controller_digital_pin_request"}
           ]
  end

  test "the VMS reads a ready, calibrated LWS at zero from the start", %{emitted: emitted} do
    assert [{:misc, "lws_status", status}] = emitted
    lws = read_back(status, @lws_status)

    assert {lws["steering_wheel_sensor_ready"], lws["steering_wheel_calibration_valid"],
            lws["steering_wheel_trimming_valid"]} == {true, true, true}

    assert angle(lws) == 0.0
  end

  test "turns clockwise at the step rate, which the LWS reports negative", %{state: state} do
    {_state, lws} = state |> powered() |> direction(true) |> stepping(1_000) |> lws_after(500)

    assert_in_delta angle(lws), -5.0, 0.05
    assert_in_delta Decimal.to_float(lws["steering_wheel_angular_speed"]), 10.0, 4.0
  end

  test "turns counter-clockwise with its direction pin low", %{state: state} do
    {_state, lws} = state |> powered() |> direction(false) |> stepping(1_000) |> lws_after(500)

    assert_in_delta angle(lws), 5.0, 0.05
  end

  test "does not turn without power", %{state: state} do
    {_state, lws} = state |> direction(true) |> stepping(1_000) |> lws_after(500)

    assert angle(lws) == 0.0
  end

  test "does not turn while its PWM is disabled", %{state: state} do
    {_state, lws} = state |> powered() |> stepping(1_000, false) |> lws_after(500)

    assert angle(lws) == 0.0
  end

  test "stops at its end stop", %{state: state} do
    {_state, lws} =
      state |> powered() |> direction(false) |> stepping(65_535) |> lws_after(60_000)

    assert_in_delta angle(lws), 500.0, 0.05
  end

  test "reports its angular speed up to the most the LWS field holds" do
    {state, _received, _emitted} =
      SteeringColumn.init(Keyword.put(@options, :steps_per_column_degree, 10))

    {_state, lws} = state |> powered() |> stepping(65_535) |> lws_after(20)

    assert Decimal.to_float(lws["steering_wheel_angular_speed"]) == 1_020.0
  end

  test "a clockwise column steers right through the steering ratio", %{state: state} do
    {state, _lws} = state |> powered() |> direction(true) |> stepping(1_000) |> lws_after(1_600)

    [{:steering, steering_rad}] = SteeringColumn.actuations(state, @vehicle, 1_600)

    assert_in_delta steering_rad, -(16.0 / 16.0) * :math.pi() / 180, 1.0e-9
  end
end
