defmodule RosBridge.Timing do
  @moduledoc """
  Time-conversion helpers shared by every publisher in the bridge.

  Most drivers tag their samples with `System.monotonic_time(:nanosecond)`;
  `OvcsDrivers.Lidar.Scan` and `OvcsDrivers.Rangefinder.Sample` carry
  system time and go through `time_message_for_system_time/1`.
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

  `wallclock_of/1` projects a monotonic capture time onto wall clock
  through `System.time_offset/1`, the VM's own offset between the two.

  ## Wall clock is not always the target

  Against a simulator it is the wrong clock entirely: Gazebo owns
  time, starts it at zero and advances it with physics, so a
  wall-clock stamp sits most of two decades away from `/tf` and
  `/odom` and any consumer that compares them drops the message.

  So `time_message_for/1` asks `RosBridge.Clock` which timescale to
  target. With no simulator clock being followed — a vehicle, and
  every test — the answer is `nil` and the wall-clock path above is
  unchanged. Drivers are unaffected either way: they keep their own
  timescale and this stays the only place that converts.
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
  def wallclock_of(monotonic_nanoseconds) when is_integer(monotonic_nanoseconds),
    do: monotonic_nanoseconds + System.time_offset(:nanosecond)

  @doc """
  Convert a kernel `CLOCK_MONOTONIC` timestamp (in nanoseconds) into
  the Erlang monotonic timescale the rest of this module expects.

  `:os.perf_counter/1` reads `CLOCK_MONOTONIC` on Linux, so sampling
  it alongside `System.monotonic_time/1` recovers the fixed offset
  between the two clocks. Both samples are taken microseconds apart,
  well inside the scheduling jitter.
  """
  def from_kernel_monotonic(kernel_nanoseconds) when is_integer(kernel_nanoseconds) do
    kernel_nanoseconds - :os.perf_counter(:nanosecond) + System.monotonic_time(:nanosecond)
  end

  @doc """
  Convert a monotonic capture timestamp into the timescale this
  bridge is publishing on: simulator time when a `/clock` is being
  followed, wall clock otherwise.
  """
  def ros_time_of(monotonic_nanoseconds) when is_integer(monotonic_nanoseconds) do
    case RosBridge.Clock.offset_ns() do
      nil -> wallclock_of(monotonic_nanoseconds)
      offset_ns -> monotonic_nanoseconds + offset_ns
    end
  end

  @doc """
  The inverse of `ros_time_of/1`: a stamp on the timescale this
  bridge publishes on, in nanoseconds, back to Erlang monotonic time.
  """
  def from_ros_time(ros_nanoseconds) when is_integer(ros_nanoseconds) do
    case RosBridge.Clock.offset_ns() do
      nil -> ros_nanoseconds - System.time_offset(:nanosecond)
      offset_ns -> ros_nanoseconds - offset_ns
    end
  end

  @doc """
  Build a `builtin_interfaces/Time` message from a monotonic
  capture timestamp. Most publishers want this directly — they
  have a `frame.capture_ns` in hand and need a `%Time{sec,
  nanosec}` to drop into a `std_msgs/Header`.
  """
  def time_message_for(monotonic_nanoseconds),
    do: time_message(ros_time_of(monotonic_nanoseconds))

  @doc """
  `time_message_for/1` for a system-time timestamp, which is what
  `OvcsDrivers.Rangefinder.Sample` and `OvcsDrivers.Lidar.Scan` carry.
  """
  def time_message_for_system_time(system_nanoseconds) do
    case RosBridge.Clock.offset_ns() do
      nil -> time_message(system_nanoseconds)
      offset_ns -> time_message(system_nanoseconds - System.time_offset(:nanosecond) + offset_ns)
    end
  end

  # Floored: `nanosec` is unsigned, and simulator time goes negative after a world reset.
  defp time_message(nanoseconds) do
    %Time{
      sec: Integer.floor_div(nanoseconds, 1_000_000_000),
      nanosec: Integer.mod(nanoseconds, 1_000_000_000)
    }
  end
end
