defmodule VmsCore.Components.OVCS.PulseRotationSensorTest do
  @moduledoc """
  Pulse frequency to shaft rotation, and nothing more: the sensor does
  not know what the shaft drives, and it speaks once per sample.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.PulseRotationSensor

  @frequency :received_pulse_pin0_frequency

  defp state, do: %{controller: Ctrl, pulses_per_revolution: D.new(1)}

  test "no pulses is exactly zero, which is what the standstill gate needs" do
    assert D.eq?(PulseRotationSensor.rotation_per_minute(D.new(0), D.new(1)), D.new(0))
  end

  test "one pulse per second on a one-pulse shaft is 60 rpm" do
    assert D.eq?(PulseRotationSensor.rotation_per_minute(D.new("1.0"), D.new(1)), D.new("60.0"))
  end

  test "more pulses per turn means a slower shaft for the same frequency, rendered plainly" do
    # The bus delivers the frequency with one decimal, as `0x7X9`
    # decodes it. Rounding to one keeps that shape, so the dashboard
    # shows 6000.0 rather than 6.00E+3.
    assert D.to_string(PulseRotationSensor.rotation_per_minute(D.new("100.0"), D.new(1))) ==
             "6000.0"

    assert D.to_string(PulseRotationSensor.rotation_per_minute(D.new("100.0"), D.new(4))) ==
             "1500.0"
  end

  test "each frequency becomes one rotation message, and a dead frame a nil one" do
    OvcsBus.subscribe("messages")

    {:noreply, _} =
      PulseRotationSensor.handle_info(
        %Message{name: @frequency, value: D.new("2.5"), source: Ctrl},
        state()
      )

    assert_received %Message{name: :rotation_per_minute, value: rpm, source: PulseRotationSensor}
    assert D.eq?(rpm, D.new("150.0"))

    {:noreply, _} =
      PulseRotationSensor.handle_info(
        %Message{name: @frequency, value: nil, source: Ctrl},
        state()
      )

    assert_received %Message{name: :rotation_per_minute, value: nil, source: PulseRotationSensor}
  end

  test "only the configured controller is read" do
    OvcsBus.subscribe("messages")

    {:noreply, _} =
      PulseRotationSensor.handle_info(
        %Message{name: @frequency, value: D.new("2.5"), source: Other},
        state()
      )

    refute_received %Message{name: :rotation_per_minute}
  end
end
