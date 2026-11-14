defmodule VisionCore.Ros2.Bag.ClockTest do
  use ExUnit.Case, async: true

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias VisionCore.Ros2.Bag.Clock
  alias VisionCore.Timing

  @start 5_000_000_000

  defp synchronized(answer), do: [synchronized?: fn -> answer end]

  describe ":system" do
    test "gives the time the Zenoh exporter stamps with" do
      clock = Clock.new(:system, @start, synchronized(false))
      monotonic = System.monotonic_time(:nanosecond)

      assert Clock.time_ns(clock, monotonic) == Timing.export_time_from_monotonic(monotonic)
    end

    test "says whether the clock was synchronized at the start" do
      assert Clock.describe(Clock.new(:system, @start, synchronized(true))) ==
               %{clock: "system", synchronized: true}

      assert Clock.describe(Clock.new(:system, @start, synchronized(false))) ==
               %{clock: "system", synchronized: false}
    end
  end

  describe ":since_start" do
    test "gives the time since the start, 0 before it" do
      clock = Clock.new(:since_start, @start, synchronized(true))

      assert Clock.time_ns(clock, @start) == 0
      assert Clock.time_ns(clock, @start + 1_500_000_000) == 1_500_000_000
      assert Clock.time_ns(clock, @start - 1) == 0
    end

    test "is described as such" do
      assert Clock.describe(Clock.new(:since_start, @start, synchronized(true))) ==
               %{clock: "since_start", synchronized: true}
    end
  end

  describe ":automatic" do
    test "is the system clock when the clock is synchronized at the start" do
      clock = Clock.new(:automatic, @start, synchronized(true))
      monotonic = System.monotonic_time(:nanosecond)

      assert Clock.describe(clock) == %{clock: "system", synchronized: true}
      assert Clock.time_ns(clock, monotonic) == Timing.export_time_from_monotonic(monotonic)
    end

    test "is the time since the start when it is not" do
      clock = Clock.new(:automatic, @start, synchronized(false))

      assert Clock.describe(clock) == %{clock: "since_start", synchronized: false}
      assert Clock.time_ns(clock, @start + 42) == 42
    end
  end

  test "without a check configured, as on a host, the clock counts as synchronized" do
    assert Application.get_env(:ros2_zenoh, :clock_synchronized?) == nil
    assert Clock.describe(Clock.new(:automatic, @start)).clock == "system"
  end

  test "stamp/1 stamps as time_ns/2 counts" do
    stamp = Clock.stamp(Clock.new(:since_start, @start, synchronized(true)))

    assert stamp.(@start + 2_000_000_123) == %Time{sec: 2, nanosec: 123}
    assert stamp.(@start - 10) == %Time{sec: 0, nanosec: 0}
  end
end
