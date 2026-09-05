defmodule RosBridge.Consumers.VelocityTest do
  @moduledoc """
  The velocity-to-wire step. `0x3A0` carries signed 24-bit integers at
  0.001, and Cantastic's encoder truncates silently, so a value outside
  the field does not raise: it comes back out as a different number,
  and for a positive overflow that number is negative. The consumer has
  to clamp, and this pins that it does, against what would reach the
  bus rather than against the intermediate float.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Decimal, as: D
  alias RosBridge.Consumers.Velocity

  @wire_limit 8_388.607

  # What Cantastic's encoder makes of a value at scale 0.001.
  defp on_the_wire(value) do
    int = value |> D.from_float() |> D.div(D.new("0.001")) |> D.round() |> D.to_integer()
    <<encoded::little-signed-integer-size(24)>> = <<int::little-signed-integer-size(24)>>
    encoded / 1000
  end

  test "in-range values pass through unchanged" do
    assert Velocity.wire_value(1.5, "linear") == 1.5
    assert Velocity.wire_value(-0.25, "angular") == -0.25
    assert Velocity.wire_value(0.0, "linear") == 0.0
  end

  test "the wire limit itself is in range" do
    assert Velocity.wire_value(@wire_limit, "linear") == @wire_limit
    assert Velocity.wire_value(-@wire_limit, "linear") == -@wire_limit
  end

  test "an oversized forward command does not arrive as reverse" do
    # Millimetres per second sent as metres per second. Unclamped, the
    # encoder wraps this to a large negative velocity.
    assert on_the_wire(9000.0) < 0

    log =
      capture_log(fn ->
        clamped = Velocity.wire_value(9000.0, "linear")
        assert clamped == @wire_limit
        assert on_the_wire(clamped) > 0
      end)

    assert log =~ "exceeds what ros2_control can carry"
  end

  test "an oversized reverse command clamps to the negative limit" do
    capture_log(fn ->
      assert Velocity.wire_value(-1.0e6, "angular") == -@wire_limit
    end)
  end
end
