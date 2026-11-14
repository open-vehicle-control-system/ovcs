defmodule Ros2Zenoh.GeometryMsgs.Msg.PoseWithCovariance do
  @moduledoc """
  ROS 2 `geometry_msgs/PoseWithCovariance`: a `Pose` followed by a
  **fixed** `float64[36]` covariance. Fixed-size arrays carry no
  length prefix in CDR, so this is a flat 56 + 288 = 344 byte run
  that needs the buffer 8-aligned on entry and leaves it 8-aligned.

  The covariance defaults to all zeros, which ROS reads as "unknown":
  a detection's position uncertainty is dominated by the stereo depth
  error, which is not propagated into a covariance matrix.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.GeometryMsgs.Msg.Pose

  @covariance_length 36

  defstruct pose: %Pose{}, covariance: List.duplicate(0.0, @covariance_length)

  def msg_definition do
    """
    # This represents a pose in free space with uncertainty.

    Pose pose

    # Row-major representation of the 6x6 covariance matrix
    # The orientation parameters use a fixed-axis representation.
    # In order, the parameters are:
    # (x, y, z, rotation about X axis, rotation about Y axis, rotation about Z axis)
    float64[36] covariance
    """
  end

  def dependencies, do: [Pose]

  def covariance_length, do: @covariance_length

  def encode(%__MODULE__{pose: pose, covariance: covariance}) do
    Pose.encode(pose) <> encode_float64_array_fixed(covariance, @covariance_length)
  end
end
