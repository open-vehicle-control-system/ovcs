defmodule VmsCore.Components.Traxxas.MotorTest do
  @moduledoc """
  Pulse frequency to speed. The constants are the Mini's: a 0.0548 m
  wheel, one pulse per turn of a shaft geared 10.5:1 to the wheel.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias VmsCore.Components.Traxxas.Motor

  @options %{pulses_per_revolution: 1, gear_ratio: 10.5, wheel_radius: 0.0548}

  test "no pulses is exactly zero, which is what the standstill gate needs" do
    assert D.eq?(Motor.speed_km_h(D.new(0), @options), D.new(0))
    assert D.eq?(Motor.rotation_per_minute(D.new(0), 1), D.new(0))
  end

  test "one wheel turn per second" do
    # 10.5 pulses per second is one wheel revolution per second:
    # 2π · 0.0548 m = 0.3443 m/s = 1.24 km/h.
    speed = Motor.speed_km_h(D.new("10.5"), @options)
    assert D.eq?(speed, D.new("1.24"))
  end

  test "shaft rpm follows pulses per revolution" do
    assert D.eq?(Motor.rotation_per_minute(D.new("100"), 1), D.new("6000"))
    assert D.eq?(Motor.rotation_per_minute(D.new("100"), 4), D.new("1500"))
  end

  test "more pulses per wheel turn means a slower vehicle for the same frequency" do
    fast = Motor.speed_km_h(D.new("100"), @options) |> D.to_float()
    slow = Motor.speed_km_h(D.new("100"), %{@options | pulses_per_revolution: 2}) |> D.to_float()
    assert_in_delta slow, fast / 2, 0.01
  end
end
