defmodule Ros2Zenoh.VisionMsgs.Msg.Pose2D do
  @moduledoc """
  ROS 2 `vision_msgs/Pose2D`: a `Point2D` position and a `float64`
  `theta`, in radians. The caller must be 8-aligned on entry.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.VisionMsgs.Msg.Point2D

  defstruct position: %Point2D{}, theta: 0.0

  def encode(%__MODULE__{position: position, theta: theta}),
    do: Point2D.encode(position) <> encode_float64(theta)
end
