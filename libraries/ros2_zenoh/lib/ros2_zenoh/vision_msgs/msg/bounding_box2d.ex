defmodule Ros2Zenoh.VisionMsgs.Msg.BoundingBox2D do
  @moduledoc """
  ROS 2 `vision_msgs/BoundingBox2D`: a `Pose2D` centre and a `size_x`
  and `size_y`, in pixels. Five `float64`s with no internal padding; the
  caller must be 8-aligned on entry.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.VisionMsgs.Msg.Pose2D

  defstruct center: %Pose2D{}, size_x: 0.0, size_y: 0.0

  def encode(%__MODULE__{center: center, size_x: size_x, size_y: size_y}),
    do: Pose2D.encode(center) <> encode_float64(size_x) <> encode_float64(size_y)
end
