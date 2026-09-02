defmodule Ros2.BuiltinInterfaces.Msg.Duration do
  @moduledoc """
  ROS 2 `builtin_interfaces/Duration`: `sec` int32 + `nanosec`
  uint32, 8 bytes, alignment 4. Same wire layout as `Time`, but a
  span rather than an instant.

  Used for `visualization_msgs/Marker.lifetime`, where it is the
  mechanism that makes a per-frame marker stream self-cleaning: a
  marker that is not refreshed within its lifetime disappears on its
  own, so a detection that goes away does not leave a box behind.
  """
  use Ros2.Common

  defstruct sec: 0, nanosec: 0

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
