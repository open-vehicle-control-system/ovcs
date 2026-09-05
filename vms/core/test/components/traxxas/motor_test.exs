defmodule VmsCore.Components.Traxxas.MotorTest do
  @moduledoc """
  Pulse frequency to speed. The constants are the Mini's: a 0.0548 m
  wheel, one pulse per turn of the spur gear, geared 2.72:1 to the wheel.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias VmsCore.Components.Traxxas.Motor

  @factor Motor.speed_factor(1, 2.72, 0.0548)

  test "no pulses is exactly zero, which is what the standstill gate needs" do
    assert D.eq?(Motor.speed_km_h(D.new(0), @factor), D.new(0))
    assert D.eq?(Motor.rotation_per_minute(D.new(0), 1), D.new(0))
  end

  test "one wheel turn per second" do
    # 2.72 pulses per second is one wheel revolution per second:
    # 2π · 0.0548 m = 0.3443 m/s = 1.24 km/h.
    assert D.eq?(Motor.speed_km_h(D.new("2.72"), @factor), D.new("1.24"))
  end

  test "shaft rpm follows pulses per revolution, as a plain integer" do
    # `D.div/2` with an integer divisor keeps the exponent at zero, so
    # the dashboard shows 6000 rather than 6.00E+3.
    assert D.to_string(Motor.rotation_per_minute(D.new("100"), 1)) == "6000"
    assert D.to_string(Motor.rotation_per_minute(D.new("100"), 4)) == "1500"
  end

  test "more pulses per wheel turn means a slower vehicle for the same frequency" do
    fast = Motor.speed_km_h(D.new("100"), @factor) |> D.to_float()
    slow = Motor.speed_km_h(D.new("100"), Motor.speed_factor(2, 2.72, 0.0548)) |> D.to_float()
    assert_in_delta slow, fast / 2, 0.01
  end
end
