defmodule VisionCore.Ros2.StampTest do
  use ExUnit.Case, async: true

  alias VisionCore.Ros2.Stamp

  describe "stamp_from_monotonic/1" do
    test "builds a Time message with a nanosec field inside one second" do
      message = Stamp.stamp_from_monotonic(System.monotonic_time(:nanosecond))
      assert message.nanosec >= 0
      assert message.nanosec < 1_000_000_000
      assert message.sec > 0
    end
  end
end
