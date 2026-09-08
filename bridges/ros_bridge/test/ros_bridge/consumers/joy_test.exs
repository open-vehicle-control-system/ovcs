defmodule RosBridge.Consumers.JoyTest do
  @moduledoc """
  Tests for the joystick-axis to CAN-value conversion.

  This is the drive path — axis 0 steers, axis 1 drives — as normalised
  positions in [-1, 1] on a signed 16-bit signal at 0.001. Cantastic
  encodes by truncation, so a value outside the field would not raise;
  it would come back out as a different number, and for a positive
  overflow that number is negative. The over-range case is therefore
  checked against what would actually reach the bus rather than against
  the intermediate decimal.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias RosBridge.Consumers.Joy

  # Matches the call sites: steering is inverted, throttle is not.
  @steering -1
  @throttle 1
  @max 1.0

  # What Cantastic's encoder would make of a value at scale 0.001, so a
  # test can assert on what reaches the wire.
  defp on_the_wire(%Decimal{} = value) do
    int = value |> D.div(D.new("0.001")) |> D.round() |> D.to_integer()
    <<encoded::little-signed-integer-size(16)>> = <<int::little-signed-integer-size(16)>>
    encoded / 1000
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
      assert_in_delta value, -@max / 2, 0.001
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
      # Unclamped, an axis past 1.0 would truncate in the signed field
      # and could come back with the wrong sign.
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

    test "clamped values stay inside [-1, 1]" do
      for axis <- [-1000.0, -1.0001, 1.0001, 1000.0] do
        value = Joy.control_value([axis, axis], 0, @steering) |> D.to_float()
        assert value >= -1.0 and value <= 1.0
      end
    end
  end

  describe "control_value/3 with unusable input" do
    test "an empty axes array reads as centre" do
      # sensor_msgs/Joy permits empty axes; without the centre fallback
      # Decimal.from_float/1 raises on nil and takes the drive path down.
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

  test "the sequence counts every sample and wraps into a byte" do
    assert Joy.next_sequence(0) == 1
    assert Joy.next_sequence(255) == 0
  end
end
