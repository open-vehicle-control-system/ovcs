defmodule RosBridge.Timing do
  @moduledoc """
  Time-conversion helpers shared by every publisher in the bridge.

  Drivers tag their samples with `System.monotonic_time(:nanosecond)`.
  Monotonic time has no relation to wall clock, but every ROS
  message's `std_msgs/Header` expects a wall-clock stamp — otherwise
  downstream `ApproximateTime` matchers (`stereo_image_proc`, `tf2`,
  …) compare nonsensical timestamps across topics.

  ## Two monotonic clocks, not one

  Erlang's monotonic time is *not* the kernel's `CLOCK_MONOTONIC`: the
  VM picks its own zero at startup, so the two differ by a large fixed
  offset (on the order of 5.8e17 ns — about 18 years — on a typical
  Linux boot). A timestamp from one clock projected with the other's
  offset lands nearly two decades off, and since
  `builtin_interfaces/Time.sec` is an int32 the result silently wraps
  negative.

  So `wallclock_of/1` and `time_message_for/1` take Erlang monotonic
  time, and anything sourced from the kernel clock — libcamera's
  `SensorTimestamp`, or the C++ capture helper's `steady_clock`
  fallback, both `CLOCK_MONOTONIC` — must go through
  `from_kernel_monotonic/1` at the driver boundary, so that
  `Frame.capture_ns` means exactly one thing everywhere.

  `wallclock_of/1` projects a monotonic capture time onto wall
  clock by sampling the offset between the two clocks at call
  time. The offset drift between successive calls is on the
  order of nanoseconds — negligible compared to the
  millisecond-scale BEAM-scheduling jitter we're removing.
  """

  alias Ros2.BuiltinInterfaces.Msg.Time

  @doc """
  Convert a monotonic capture timestamp (in nanoseconds) into a
  wall-clock timestamp (also in nanoseconds).

  The input is whatever a driver wrote into
  `RosBridge.Camera.Frame.capture_ns` (or any equivalent
  monotonic timestamp). The output matches
  `System.system_time(:nanosecond)`.
  """
  def wallclock_of(monotonic_nanoseconds) when is_integer(monotonic_nanoseconds) do
    monotonic_now = System.monotonic_time(:nanosecond)
    wallclock_now = System.system_time(:nanosecond)
    monotonic_nanoseconds + (wallclock_now - monotonic_now)
  end

  @doc """
  Convert a kernel `CLOCK_MONOTONIC` timestamp (in nanoseconds) into
  the Erlang monotonic timescale the rest of this module expects.

  `:os.perf_counter/1` reads `CLOCK_MONOTONIC` on Linux, so sampling
  it alongside `System.monotonic_time/1` recovers the fixed offset
  between the two clocks. Both samples are taken microseconds apart,
  which is well inside the jitter we already tolerate.
  """
  def from_kernel_monotonic(kernel_nanoseconds) when is_integer(kernel_nanoseconds) do
    kernel_nanoseconds - :os.perf_counter(:nanosecond) + System.monotonic_time(:nanosecond)
  end

  @doc """
  Build a `builtin_interfaces/Time` message from a monotonic
  capture timestamp. Most publishers want this directly — they
  have a `frame.capture_ns` in hand and need a `%Time{sec,
  nanosec}` to drop into a `std_msgs/Header`.
  """
  def time_message_for(monotonic_nanoseconds) do
    wallclock_nanoseconds = wallclock_of(monotonic_nanoseconds)

    %Time{
      sec: div(wallclock_nanoseconds, 1_000_000_000),
      nanosec: rem(wallclock_nanoseconds, 1_000_000_000)
    }
  end
end
