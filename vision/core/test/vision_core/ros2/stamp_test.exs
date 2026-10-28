defmodule VisionCore.Ros2.StampTest do
  use ExUnit.Case, async: true

  alias VisionCore.Ros2.Stamp

  # Generous enough to survive a loaded CI runner.
  @tolerance_ns 500_000_000

  describe "monotonic_from_ros_time/1" do
    test "undoes ros_time_from_monotonic/1" do
      now = System.monotonic_time(:nanosecond)

      assert_in_delta Stamp.monotonic_from_ros_time(Stamp.ros_time_from_monotonic(now)),
                      now,
                      @tolerance_ns
    end
  end

  describe "stamp_from_monotonic/1" do
    test "builds a Time message with a nanosec field inside one second" do
      message = Stamp.stamp_from_monotonic(System.monotonic_time(:nanosecond))
      assert message.nanosec >= 0
      assert message.nanosec < 1_000_000_000
      assert message.sec > 0
    end
  end
end
