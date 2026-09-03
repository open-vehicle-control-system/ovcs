defmodule Ros2.GeometryMsgs.Msg.PoseWithCovariance do
  @moduledoc """
  ROS 2 `geometry_msgs/PoseWithCovariance`: a `Pose` followed by a
  **fixed** `float64[36]` covariance. Fixed-size arrays carry no
  length prefix in CDR, so this is a flat 56 + 288 = 344 byte run
  that needs the buffer 8-aligned on entry and leaves it 8-aligned.

  We publish an all-zero covariance. In ROS convention that reads as
  "unknown", which is honest: a detection's position uncertainty is
  dominated by the stereo depth error, and we do not currently
  propagate that through to a covariance matrix.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.Pose

  @covariance_length 36

  defstruct pose: %Pose{}, covariance: List.duplicate(0.0, @covariance_length)

  def covariance_length, do: @covariance_length

  def encode(%__MODULE__{pose: pose, covariance: covariance}) do
    Pose.encode(pose) <> encode_float64_array_fixed(covariance, @covariance_length)
  end
end
