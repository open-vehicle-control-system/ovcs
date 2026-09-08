defmodule RosBridge.Consumers.VelocityTest do
  @moduledoc """
  The velocity-to-wire step. `0x2B1` carries signed 16-bit integers,
  linear at 0.01 and angular at 0.001, and Cantastic's encoder
  truncates silently, so a value outside the field does not raise: it
  comes back out as a different number, and for a positive overflow
  that number is negative. The consumer has to clamp, and this pins
  that it does, against what would reach the bus rather than against
  the intermediate float.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Decimal, as: D
  alias RosBridge.Consumers.Velocity

  @linear_limit 327.67
  @angular_limit 32.767

  # What Cantastic's encoder makes of a linear value at scale 0.01.
  defp on_the_wire(value) do
    int = value |> D.from_float() |> D.div(D.new("0.01")) |> D.round() |> D.to_integer()
    <<encoded::little-signed-integer-size(16)>> = <<int::little-signed-integer-size(16)>>
    encoded / 100
  end

  test "in-range values pass through unchanged" do
    assert Velocity.wire_value(1.5, "linear") == 1.5
    assert Velocity.wire_value(-0.25, "angular") == -0.25
    assert Velocity.wire_value(0.0, "linear") == 0.0
  end

  test "the wire limits themselves are in range" do
    assert Velocity.wire_value(@linear_limit, "linear") == @linear_limit
    assert Velocity.wire_value(-@linear_limit, "linear") == -@linear_limit
    assert Velocity.wire_value(@angular_limit, "angular") == @angular_limit
  end

  test "an oversized forward command does not arrive as reverse" do
    # Millimetres per second sent as metres per second. Unclamped, the
    # encoder wraps this to a large negative velocity.
    assert on_the_wire(9000.0) < 0

    log =
      capture_log(fn ->
        clamped = Velocity.wire_value(9000.0, "linear")
        assert clamped == @linear_limit
        assert on_the_wire(clamped) > 0
      end)

    assert log =~ "exceeds what ros_velocity_command can carry"
  end

  test "an oversized reverse command clamps to the negative limit" do
    capture_log(fn ->
      assert Velocity.wire_value(-1.0e6, "angular") == -@angular_limit
    end)
  end

  test "the sequence counts every sample and wraps into a byte" do
    assert Velocity.next_sequence(0) == 1
    assert Velocity.next_sequence(255) == 0
  end
end
