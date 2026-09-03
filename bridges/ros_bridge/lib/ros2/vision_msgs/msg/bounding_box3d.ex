defmodule Ros2.VisionMsgs.Msg.BoundingBox3D do
  @moduledoc """
  ROS 2 `vision_msgs/BoundingBox3D`: a `Pose` centre and a `Vector3`
  size, in metres. Ten `float64`s with no internal padding; the
  caller must be 8-aligned on entry.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.{Pose, Vector3}

  defstruct center: %Pose{}, size: %Vector3{}

  def encode(%__MODULE__{center: center, size: size}) do
    Pose.encode(center) <> Vector3.encode(size)
  end
end
