defmodule Ros2.GeometryMsgs.Msg.Point do
  @moduledoc """
  ROS 2 `geometry_msgs/Point`: three `float64`s (x, y, z), 24 bytes
  total. Structurally identical to `Vector3` — ROS keeps them
  distinct because one is a position and the other a displacement,
  and message definitions are not interchangeable even when their
  wire layout is.

  Callers must ensure the encode buffer is 8-aligned before nesting
  this struct.
  """
  use Ros2.Common

  defstruct x: 0.0, y: 0.0, z: 0.0

  def encode(%__MODULE__{x: x, y: y, z: z}) do
    encode_float64(x) <> encode_float64(y) <> encode_float64(z)
  end
end
