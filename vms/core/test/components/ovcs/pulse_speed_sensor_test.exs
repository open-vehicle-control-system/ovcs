defmodule VmsCore.Components.OVCS.PulseSpeedSensorTest do
  @moduledoc """
  Pulse frequency to speed. The constants are the Mini's: a 0.0548 m
  wheel, one pulse per turn of the spur gear, geared 2.72:1 to the wheel.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias VmsCore.Components.OVCS.PulseSpeedSensor

  @factor PulseSpeedSensor.speed_factor(1, 2.72, 0.0548)
  @pulses_per_wheel_revolution D.from_float(2.72)

  test "no pulses is exactly zero, which is what the standstill gate needs" do
    assert D.eq?(PulseSpeedSensor.speed_km_h(D.new(0), @factor), D.new(0))

    assert D.eq?(
             PulseSpeedSensor.wheel_rotation_per_minute(D.new(0), @pulses_per_wheel_revolution),
             D.new(0)
           )
  end

  test "one wheel turn per second" do
    # 2.72 pulses per second is one wheel revolution per second:
    # 2π · 0.0548 m = 0.3443 m/s = 1.24 km/h, and 60 wheel rpm.
    assert D.eq?(PulseSpeedSensor.speed_km_h(D.new("2.72"), @factor), D.new("1.24"))

    assert D.eq?(
             PulseSpeedSensor.wheel_rotation_per_minute(
               D.new("2.72"),
               @pulses_per_wheel_revolution
             ),
             D.new("60.0")
           )
  end

  test "wheel rpm divides by the whole chain and renders plainly" do
    # The bus delivers the frequency with one decimal, as `0x7X9`
    # decodes it. Rounding to one keeps that shape, so the dashboard
    # shows 6000.0 rather than 6.00E+3.
    assert D.to_string(PulseSpeedSensor.wheel_rotation_per_minute(D.new("100.0"), D.new(1))) ==
             "6000.0"

    assert D.to_string(PulseSpeedSensor.wheel_rotation_per_minute(D.new("100.0"), D.new(4))) ==
             "1500.0"
  end

  test "the sensed shaft is not the wheel" do
    # A magnet on a shaft geared 2.72:1 to the wheel turns 2.72 times
    # per wheel turn, so the wheel is the slower of the two.
    on_shaft =
      PulseSpeedSensor.wheel_rotation_per_minute(D.new("100.0"), @pulses_per_wheel_revolution)

    on_wheel = PulseSpeedSensor.wheel_rotation_per_minute(D.new("100.0"), D.new(1))
    assert D.lt?(on_shaft, on_wheel)
  end

  test "before the first frequency, speed and rpm are unknown, not zero" do
    {:ok, state} =
      PulseSpeedSensor.init(%{
        controller: Ctrl,
        pulses_per_revolution: 1,
        gear_ratio: 2.72,
        wheel_radius: 0.0548
      })

    {:ok, :cancel} = :timer.cancel(state.loop_timer)
    assert state.speed == nil
    assert state.wheel_rotation_per_minute == nil

    message = %OvcsBus.Message{
      name: :received_pulse_pin0_frequency,
      value: D.new("2.72"),
      source: Ctrl
    }

    {:noreply, state} = PulseSpeedSensor.handle_info(message, state)
    assert D.eq?(state.speed, D.new("1.24"))
    assert D.eq?(state.wheel_rotation_per_minute, D.new("60.0"))

    dead = %OvcsBus.Message{name: :received_pulse_pin0_frequency, value: nil, source: Ctrl}
    {:noreply, state} = PulseSpeedSensor.handle_info(dead, state)
    assert state.speed == nil
    assert state.wheel_rotation_per_minute == nil
  end

  test "more pulses per wheel turn means a slower vehicle for the same frequency" do
    fast = PulseSpeedSensor.speed_km_h(D.new("100"), @factor) |> D.to_float()

    slow =
      PulseSpeedSensor.speed_km_h(D.new("100"), PulseSpeedSensor.speed_factor(2, 2.72, 0.0548))
      |> D.to_float()

    assert_in_delta slow, fast / 2, 0.01
  end
end
