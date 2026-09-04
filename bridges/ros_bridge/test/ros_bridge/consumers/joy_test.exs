defmodule RosBridge.Consumers.JoyTest do
  @moduledoc """
  Tests for the joystick-axis to CAN-value conversion.

  This is the drive path — axis 0 steers, axis 1 drives — and it had no
  tests. Both signals are signed 32-bit, and Cantastic encodes with
  `<<int::little-signed-integer-size(32)>>`, which **truncates
  silently**. So a value that overflows the field does not raise; it
  comes back out as a different number, and for a positive overflow
  that number is negative.

  The over-range case is checked by doing the truncation these tests, so
  the assertion is about the value that would actually reach the bus
  rather than about the intermediate decimal.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias RosBridge.Consumers.Joy

  @max 2 ** 31 - 1
  # Matches the call sites: steering is inverted, throttle is not.
  @steering -@max
  @throttle @max

  # What Cantastic's encoder would make of a value, so a test can assert
  # on what reaches the wire.
  defp on_the_wire(%Decimal{} = value) do
    int = value |> D.round() |> D.to_integer()
    <<encoded::little-signed-integer-size(32)>> = <<int::little-signed-integer-size(32)>>
    encoded
  end

  describe "control_value/3 in normal range" do
    test "centre is zero on both axes" do
      assert D.equal?(Joy.control_value([0.0, 0.0], 0, @steering), D.new(0))
      assert D.equal?(Joy.control_value([0.0, 0.0], 1, @throttle), D.new(0))
    end

    test "steering is inverted, throttle is not" do
      # The sign convention is the whole reason the two call sites pass
      # different scales; swapping them would steer the wrong way.
      assert on_the_wire(Joy.control_value([1.0, 1.0], 0, @steering)) == -@max
      assert on_the_wire(Joy.control_value([1.0, 1.0], 1, @throttle)) == @max
    end

    test "full lock the other way" do
      assert on_the_wire(Joy.control_value([-1.0, -1.0], 0, @steering)) == @max
      assert on_the_wire(Joy.control_value([-1.0, -1.0], 1, @throttle)) == -@max
    end

    test "half deflection is half scale" do
      value = on_the_wire(Joy.control_value([0.5, 0.0], 0, @steering))
      assert_in_delta value, -@max / 2, 2
    end

    test "each axis is read from its own index" do
      # A transposition here would put throttle on the steering signal
      # and be entirely invisible until the vehicle moved.
      assert on_the_wire(Joy.control_value([1.0, 0.0], 0, @steering)) == -@max
      assert on_the_wire(Joy.control_value([1.0, 0.0], 1, @throttle)) == 0
    end
  end

  describe "control_value/3 out of range" do
    test "an over-range axis does not flip sign on the wire" do
      # The bug this replaces: 1.9 * (2^31-1) = 4_080_218_929, which
      # truncated into a signed 32-bit field reads as -214_748_367 —
      # full positive lock arriving as a tenth of negative lock.
      wire = on_the_wire(Joy.control_value([1.9, 0.0], 0, @steering))
      assert wire == -@max
      assert wire < 0, "steering commanded the wrong way for a positive axis"
    end

    test "a large negative axis clamps rather than wrapping positive" do
      wire = on_the_wire(Joy.control_value([-5.0, 0.0], 0, @steering))
      assert wire == @max
      assert wire > 0
    end

    test "throttle clamps too" do
      assert on_the_wire(Joy.control_value([0.0, 3.5], 1, @throttle)) == @max
      assert on_the_wire(Joy.control_value([0.0, -3.5], 1, @throttle)) == -@max
    end

    test "clamped values stay inside the signed 32-bit field" do
      for axis <- [-1000.0, -1.0001, 1.0001, 1000.0] do
        int = Joy.control_value([axis, axis], 0, @steering) |> D.round() |> D.to_integer()
        assert int >= -2_147_483_648 and int <= 2_147_483_647
      end
    end
  end

  describe "control_value/3 with unusable input" do
    test "an empty axes array reads as centre" do
      # sensor_msgs/Joy permits empty axes, and this used to raise
      # FunctionClauseError in Decimal.from_float/1, taking the drive
      # path down on every frame.
      assert D.equal?(Joy.control_value([], 0, @steering), D.new(0))
      assert D.equal?(Joy.control_value([], 1, @throttle), D.new(0))
    end

    test "a controller with fewer axes than we read reads as centre" do
      assert D.equal?(Joy.control_value([0.5], 1, @throttle), D.new(0))
    end

    test "nil axes reads as centre" do
      assert D.equal?(Joy.control_value(nil, 0, @steering), D.new(0))
    end

    test "an integer-valued axis is accepted" do
      # Decimal.from_float/1 has no integer clause, so `0` rather than
      # `0.0` would have raised.
      assert D.equal?(Joy.control_value([0, 0], 0, @steering), D.new(0))
      assert on_the_wire(Joy.control_value([1, 0], 0, @steering)) == -@max
    end

    test "a non-numeric axis reads as centre rather than raising" do
      assert D.equal?(Joy.control_value([:up, nil], 0, @steering), D.new(0))
    end
  end
end
