defmodule Ros2Zenoh.BuiltinInterfaces.Msg.Duration do
  @moduledoc """
  ROS 2 `builtin_interfaces/Duration`: `sec` int32 + `nanosec`
  uint32, 8 bytes, alignment 4. Same wire layout as `Time`, but a
  span rather than an instant.

  Used for `visualization_msgs/Marker.lifetime`, where it is the
  mechanism that makes a per-frame marker stream self-cleaning: a
  marker that is not refreshed within its lifetime disappears on its
  own, so a detection that goes away does not leave a box behind.
  """
  use Ros2Zenoh.Common

  defstruct sec: 0, nanosec: 0

  def msg_definition do
    """
    # Duration defines a period between two time points.
    # Messages of this datatype are of ROS Time following this design:
    # https://design.ros2.org/articles/clock_and_time.html

    # The seconds component, valid over all int32 values.
    int32 sec

    # The nanoseconds component, valid in the range [0, 1e9), to be added to the seconds component.\s
    # e.g.
    # The duration -1.7 seconds is represented as {sec: -2, nanosec: 3e8}
    # The duration 1.7 seconds is represented as {sec: 1, nanosec: 7e8}
    uint32 nanosec
    """
  end

  def dependencies, do: []

  @doc "Build a Duration from a millisecond span."
  def from_milliseconds(milliseconds) when is_integer(milliseconds) and milliseconds >= 0 do
    %__MODULE__{
      sec: div(milliseconds, 1_000),
      nanosec: rem(milliseconds, 1_000) * 1_000_000
    }
  end

  def encode(%__MODULE__{sec: sec, nanosec: nanosec}) do
    encode_int32(sec) <> encode_uint32(nanosec)
  end
end
