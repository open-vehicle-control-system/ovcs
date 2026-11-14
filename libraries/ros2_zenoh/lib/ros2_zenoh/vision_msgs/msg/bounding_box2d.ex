defmodule Ros2Zenoh.VisionMsgs.Msg.BoundingBox2D do
  @moduledoc """
  ROS 2 `vision_msgs/BoundingBox2D`: a `Pose2D` centre and a `size_x`
  and `size_y`, in pixels. Five `float64`s with no internal padding; the
  caller must be 8-aligned on entry.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.VisionMsgs.Msg.Pose2D

  defstruct center: %Pose2D{}, size_x: 0.0, size_y: 0.0

  def msg_definition do
    """
    # A 2D bounding box that can be rotated about its center.
    # All dimensions are in pixels, but represented using floating-point
    #   values to allow sub-pixel precision. If an exact pixel crop is required
    #   for a rotated bounding box, it can be calculated using Bresenham's line
    #   algorithm.

    # The 2D position (in pixels) and orientation of the bounding box center.
    vision_msgs/Pose2D center

    # The total size (in pixels) of the bounding box surrounding the object relative
    #   to the pose of its center.
    float64 size_x
    float64 size_y
    """
  end

  def dependencies, do: [Pose2D]

  def encode(%__MODULE__{center: center, size_x: size_x, size_y: size_y}),
    do: Pose2D.encode(center) <> encode_float64(size_x) <> encode_float64(size_y)
end
