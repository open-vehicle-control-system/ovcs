defmodule VisionCore.Timing do
  @moduledoc """
  Conversions between the clocks a frame's timestamp can come from.

  Camera drivers tag their frames with `System.monotonic_time(:nanosecond)`.
  Monotonic time has no relation to wall clock; `VisionCore.Ros2.Stamp`
  turns it into the stamps ROS messages carry.

  ## Two monotonic clocks, not one

  Erlang's monotonic time is *not* the kernel's `CLOCK_MONOTONIC`: the
  VM picks its own zero at startup, so the two differ by a large fixed
  offset (on the order of 5.8e17 ns — about 18 years — on a typical
  Linux boot). A timestamp from one clock projected with the other's
  offset lands nearly two decades off, and since
  `builtin_interfaces/Time.sec` is an int32 the result silently wraps
  negative.

  So `system_time_from_monotonic/1` takes Erlang monotonic time, and anything sourced from the kernel clock —
  libcamera's `SensorTimestamp`, or `camera_capture`'s
  `clock_gettime(CLOCK_MONOTONIC)` fallback — must go through
  `monotonic_from_kernel/1` at the driver boundary, so that
  `Frame.capture_ns` means exactly one thing everywhere.

  `system_time_from_monotonic/1` projects a monotonic capture time onto
  wall clock through `System.time_offset/1`, the VM's own offset between
  the two.
  """

  @doc """
  Convert a monotonic capture timestamp (in nanoseconds) into a
  wall-clock timestamp (also in nanoseconds).

  The input is whatever a driver wrote into
  `VisionCore.Camera.Frame.capture_ns` (or any equivalent
  monotonic timestamp). The output matches
  `System.system_time(:nanosecond)`.
  """
  def system_time_from_monotonic(monotonic_nanoseconds) when is_integer(monotonic_nanoseconds),
    do: monotonic_nanoseconds + System.time_offset(:nanosecond)

  @doc """
  Convert a kernel `CLOCK_MONOTONIC` timestamp (in nanoseconds) into
  the Erlang monotonic timescale the rest of this module expects.

  `:os.perf_counter/1` reads `CLOCK_MONOTONIC` on Linux, so sampling
  it alongside `System.monotonic_time/1` recovers the fixed offset
  between the two clocks. Both samples are taken microseconds apart,
  well inside the scheduling jitter.
  """
  def monotonic_from_kernel(kernel_nanoseconds) when is_integer(kernel_nanoseconds) do
    kernel_nanoseconds - :os.perf_counter(:nanosecond) + System.monotonic_time(:nanosecond)
  end
end
