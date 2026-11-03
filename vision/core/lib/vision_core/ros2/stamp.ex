defmodule VisionCore.Ros2.Stamp do
  @moduledoc """
  ROS time for the vision core's messages: the `builtin_interfaces/Time`
  stamps of every `std_msgs/Header` it publishes, from the Erlang
  monotonic timestamps camera drivers write into `Frame.capture_ns`,
  on the timescale `VisionCore.Timing.export_time_from_monotonic/1`
  projects them onto: simulator time when a `/clock` is followed, wall
  clock otherwise.

  A ROS message's header expects a wall-clock stamp — otherwise
  downstream `ApproximateTime` matchers (`stereo_image_proc`, `tf2`,
  …) compare nonsensical timestamps across topics.
  """

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time
  alias VisionCore.Timing

  @doc """
  Build a `builtin_interfaces/Time` message from a monotonic
  capture timestamp. Most publishers want this directly — they
  have a `frame.capture_ns` in hand and need a `%Time{sec,
  nanosec}` to drop into a `std_msgs/Header`.
  """
  def stamp_from_monotonic(monotonic_nanoseconds),
    do: stamp(Timing.export_time_from_monotonic(monotonic_nanoseconds))

  # Floored: `nanosec` is unsigned, and simulator time goes negative after a world reset.
  defp stamp(nanoseconds) do
    %Time{
      sec: Integer.floor_div(nanoseconds, 1_000_000_000),
      nanosec: Integer.mod(nanoseconds, 1_000_000_000)
    }
  end
end
