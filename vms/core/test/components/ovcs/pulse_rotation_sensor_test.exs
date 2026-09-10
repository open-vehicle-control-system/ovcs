defmodule VmsCore.Components.OVCS.PulseRotationSensorTest do
  @moduledoc """
  Pulse frequency to shaft rotation, and nothing more: the sensor does
  not know what the shaft drives.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.PulseRotationSensor

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

  test "before the first frequency the rotation is unknown, not zero" do
    {:ok, state} = PulseRotationSensor.init(%{controller: Ctrl, pulses_per_revolution: 1})
    {:ok, :cancel} = :timer.cancel(state.loop_timer)
    assert state.rotation_per_minute == nil

    message = %Message{name: :received_pulse_pin0_frequency, value: D.new("2.5"), source: Ctrl}
    {:noreply, state} = PulseRotationSensor.handle_info(message, state)
    assert D.eq?(state.rotation_per_minute, D.new("150.0"))

    dead = %Message{name: :received_pulse_pin0_frequency, value: nil, source: Ctrl}
    {:noreply, state} = PulseRotationSensor.handle_info(dead, state)
    assert state.rotation_per_minute == nil
  end

  test "only the configured controller is read" do
    {:ok, state} = PulseRotationSensor.init(%{controller: Ctrl, pulses_per_revolution: 1})
    {:ok, :cancel} = :timer.cancel(state.loop_timer)

    message = %Message{name: :received_pulse_pin0_frequency, value: D.new("2.5"), source: Other}
    {:noreply, state} = PulseRotationSensor.handle_info(message, state)
    assert state.rotation_per_minute == nil
  end
end
