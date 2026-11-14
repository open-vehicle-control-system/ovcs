defmodule Ros2Zenoh.VisionMsgs.Msg.BoundingBox3D do
  @moduledoc """
  ROS 2 `vision_msgs/BoundingBox3D`: a `Pose` centre and a `Vector3`
  size, in metres. Ten `float64`s with no internal padding; the
  caller must be 8-aligned on entry.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.GeometryMsgs.Msg.{Pose, Vector3}

  defstruct center: %Pose{}, size: %Vector3{}

  def msg_definition do
    """
    # A 3D bounding box that can be positioned and rotated about its center (6 DOF)
    # Dimensions of this box are in meters, and as such, it may be migrated to
    #   another package, such as geometry_msgs, in the future.

    # The 3D position and orientation of the bounding box center
    geometry_msgs/Pose center

    # The total size of the bounding box, in meters, surrounding the object's center
    #   pose.
    geometry_msgs/Vector3 size
    """
  end

  def dependencies, do: [Pose, Vector3]

  def encode(%__MODULE__{center: center, size: size}) do
    Pose.encode(center) <> Vector3.encode(size)
  end
end
