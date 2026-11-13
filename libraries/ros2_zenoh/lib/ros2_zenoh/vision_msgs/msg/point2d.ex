defmodule Ros2Zenoh.VisionMsgs.Msg.Point2D do
  @moduledoc """
  ROS 2 `vision_msgs/Point2D`: two `float64`s, `x` and `y`, in pixels. The
  caller must be 8-aligned on entry.
  """
  use Ros2Zenoh.Common

  defstruct x: 0.0, y: 0.0

  def encode(%__MODULE__{x: x, y: y}), do: encode_float64(x) <> encode_float64(y)
end
