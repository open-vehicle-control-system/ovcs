defmodule RosBridge.TimingTest do
  use ExUnit.Case, async: true

  alias RosBridge.Timing

  # Generous enough to survive a loaded CI runner.
  @tolerance_ns 500_000_000

  describe "system_time_from_monotonic/1" do
    test "projects an Erlang monotonic timestamp onto wall clock" do
      now = System.monotonic_time(:nanosecond)

      assert_in_delta Timing.system_time_from_monotonic(now),
                      System.system_time(:nanosecond),
                      @tolerance_ns
    end
  end

  test "ROS timestamps round trip to their capture time" do
    captured_at_ns = System.monotonic_time(:nanosecond) - 123_456_789

    assert captured_at_ns |> Timing.stamp_from_monotonic() |> Timing.monotonic_from_stamp() ==
             captured_at_ns
  end

  describe "stamp_from_monotonic/1" do
    test "builds a Time message with a nanosec field inside one second" do
      message = Timing.stamp_from_monotonic(System.monotonic_time(:nanosecond))
      assert message.nanosec >= 0
      assert message.nanosec < 1_000_000_000
      assert message.sec > 0
    end
  end
end
