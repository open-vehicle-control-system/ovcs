defmodule RosBridge.TimingTest do
  use ExUnit.Case, async: true

  alias RosBridge.Timing

  # Generous enough to survive a loaded CI runner, tight enough that
  # confusing the two monotonic clocks (~18 years apart) can't pass.
  @tolerance_ns 500_000_000

  describe "wallclock_of/1" do
    test "projects an Erlang monotonic timestamp onto wall clock" do
      now = System.monotonic_time(:nanosecond)
      assert_in_delta Timing.wallclock_of(now), System.system_time(:nanosecond), @tolerance_ns
    end
  end

  describe "from_kernel_monotonic/1" do
    test "converts a kernel CLOCK_MONOTONIC timestamp onto the Erlang timescale" do
      kernel_now = :os.perf_counter(:nanosecond)

      assert_in_delta Timing.from_kernel_monotonic(kernel_now),
                      System.monotonic_time(:nanosecond),
                      @tolerance_ns
    end

    # The bug this guards: feeding a kernel timestamp straight to
    # wallclock_of/1 lands ~18 years out, and since
    # builtin_interfaces/Time.sec is an int32 the stamp wraps negative.
    test "a converted kernel timestamp yields a sane wall-clock stamp" do
      kernel_now = :os.perf_counter(:nanosecond)
      wallclock = Timing.wallclock_of(Timing.from_kernel_monotonic(kernel_now))

      assert_in_delta wallclock, System.system_time(:nanosecond), @tolerance_ns

      seconds = div(wallclock, 1_000_000_000)
      assert seconds > 0
      assert seconds < 2_147_483_647, "seconds must fit builtin_interfaces/Time.sec (int32)"
    end

    test "an unconverted kernel timestamp would not fit int32 seconds" do
      # Documents why the conversion exists rather than asserting on
      # the broken path in production code.
      unconverted = Timing.wallclock_of(:os.perf_counter(:nanosecond))
      assert div(unconverted, 1_000_000_000) > 2_147_483_647
    end
  end

  describe "time_message_for/1" do
    test "builds a Time message with a nanosec field inside one second" do
      message = Timing.time_message_for(System.monotonic_time(:nanosecond))
      assert message.nanosec >= 0
      assert message.nanosec < 1_000_000_000
      assert message.sec > 0
    end
  end
end
