defmodule RosBridge.Timing do
  @moduledoc """
  Time-conversion helpers shared by every publisher in the bridge.

  Camera and sensor drivers tag their samples with
  `System.monotonic_time(:nanosecond)` — or, on the perception
  target, libcamera's `SensorTimestamp`, which also comes from
  `CLOCK_MONOTONIC`. Monotonic time has no relation to wall
  clock, but every ROS message's `std_msgs/Header` expects a
  wall-clock stamp — otherwise downstream `ApproximateTime`
  matchers (`stereo_image_proc`, `tf2`, …) compare nonsensical
  timestamps across topics.

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
