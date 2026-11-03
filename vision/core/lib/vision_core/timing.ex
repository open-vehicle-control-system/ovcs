defmodule VisionCore.Timing do
  @moduledoc """
  Conversions between the clocks a frame's timestamp can come from.

  Camera drivers tag their frames with `System.monotonic_time(:nanosecond)`.
  Monotonic time has no relation to wall clock: an exporter stamps what
  it takes out of the unit on the timescale `export_time_from_monotonic/1`
  projects it onto, as `VisionCore.Ros2.Stamp` does for the stamps ROS
  messages carry.

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

  ## Wall clock is not always the target

  Against a simulator it is the wrong clock entirely: Gazebo owns
  time, starts it at zero and advances it with physics, so a
  wall-clock stamp sits most of two decades away from `/tf` and
  `/odom` and any consumer that compares them drops the message.

  So `export_time_from_monotonic/1` asks `VisionCore.Ros2.Clock`, which
  follows the simulator's `/clock`, for its offset. With no simulator
  clock being followed — a vehicle, and every test — there is none, and
  the time is wall clock. Drivers are unaffected either way: they keep
  their own timescale and this stays the only place that converts.
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
  Convert a monotonic capture timestamp (in nanoseconds) onto the
  timescale the exporters stamp with (also in nanoseconds): simulator
  time when `VisionCore.Ros2.Clock` follows a `/clock`, wall clock
  otherwise.
  """
  @spec export_time_from_monotonic(integer()) :: integer()
  def export_time_from_monotonic(monotonic_nanoseconds) when is_integer(monotonic_nanoseconds) do
    case VisionCore.Ros2.Clock.offset_ns() do
      nil -> system_time_from_monotonic(monotonic_nanoseconds)
      offset_ns -> monotonic_nanoseconds + offset_ns
    end
  end

  @doc """
  The inverse of `export_time_from_monotonic/1`: a timestamp on the
  timescale the exporters stamp with, in nanoseconds, back to Erlang
  monotonic time.
  """
  @spec monotonic_from_export_time(integer()) :: integer()
  def monotonic_from_export_time(export_nanoseconds) when is_integer(export_nanoseconds) do
    case VisionCore.Ros2.Clock.offset_ns() do
      nil -> export_nanoseconds - System.time_offset(:nanosecond)
      offset_ns -> export_nanoseconds - offset_ns
    end
  end

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
