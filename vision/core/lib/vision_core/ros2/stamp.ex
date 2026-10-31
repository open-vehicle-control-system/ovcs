defmodule VisionCore.Ros2.Stamp do
  @moduledoc """
  ROS time for the vision core's messages: the `builtin_interfaces/Time`
  stamps of every `std_msgs/Header` it publishes, from the Erlang
  monotonic timestamps camera drivers write into `Frame.capture_ns`
  (see `VisionCore.Timing`).

  A ROS message's header expects a wall-clock stamp — otherwise
  downstream `ApproximateTime` matchers (`stereo_image_proc`, `tf2`,
  …) compare nonsensical timestamps across topics.

  ## Wall clock is not always the target

  Against a simulator it is the wrong clock entirely: Gazebo owns
  time, starts it at zero and advances it with physics, so a
  wall-clock stamp sits most of two decades away from `/tf` and
  `/odom` and any consumer that compares them drops the message.

  So `stamp_from_monotonic/1` asks `VisionCore.Ros2.Clock` which
  timescale to target. With no simulator clock being followed — a
  vehicle, and every test — the answer is `nil` and stamps are wall
  clock, through `VisionCore.Timing.system_time_from_monotonic/1`.
  Drivers are unaffected either way: they keep their own timescale and
  this stays the only place that converts.
  """

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias VisionCore.Timing

  @doc """
  Convert a monotonic capture timestamp into the timescale this
  vision core is publishing on: simulator time when a `/clock` is being
  followed, wall clock otherwise.
  """
  def ros_time_from_monotonic(monotonic_nanoseconds) when is_integer(monotonic_nanoseconds) do
    case VisionCore.Ros2.Clock.offset_ns() do
      nil -> Timing.system_time_from_monotonic(monotonic_nanoseconds)
      offset_ns -> monotonic_nanoseconds + offset_ns
    end
  end

  @doc """
  The inverse of `ros_time_from_monotonic/1`: a stamp on the timescale
  this app publishes on, in nanoseconds, back to Erlang monotonic
  time.
  """
  def monotonic_from_ros_time(ros_nanoseconds) when is_integer(ros_nanoseconds) do
    case VisionCore.Ros2.Clock.offset_ns() do
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
  def stamp_from_monotonic(monotonic_nanoseconds),
    do: stamp(ros_time_from_monotonic(monotonic_nanoseconds))

  # Floored: `nanosec` is unsigned, and simulator time goes negative after a world reset.
  defp stamp(nanoseconds) do
    %Time{
      sec: Integer.floor_div(nanoseconds, 1_000_000_000),
      nanosec: Integer.mod(nanoseconds, 1_000_000_000)
    }
  end
end
