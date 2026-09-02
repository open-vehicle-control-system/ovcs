defmodule Ros2.GeometryMsgs.Msg.Pose do
  @moduledoc """
  ROS 2 `geometry_msgs/Pose`: a `Point` position followed by a
  `Quaternion` orientation — seven `float64`s, 56 bytes, no internal
  padding. Callers must ensure the encode buffer is 8-aligned before
  nesting this struct.

  The default is the identity pose, which is what a marker whose
  geometry is fully described by its position needs.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.{Point, Quaternion}

  defstruct position: %Point{}, orientation: %Quaternion{x: 0.0, y: 0.0, z: 0.0, w: 1.0}

  def encode(%__MODULE__{position: position, orientation: orientation}) do
    Point.encode(position) <> Quaternion.encode(orientation)
  end
end
