defmodule Ros2.GeometryMsgs.Msg.TwistWithCovariance do
  @moduledoc """
  ROS 2 `geometry_msgs/TwistWithCovariance`: a `Twist` followed by a
  **fixed** `float64[36]` covariance — the same shape as
  `PoseWithCovariance`, 48 + 288 bytes of float64 run, 8-aligned on
  entry and on exit.

  An all-zero covariance reads as "unknown" by ROS convention, which
  is what a dead-reckoned twist honestly is until the sensor noise is
  characterised.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.Twist

  @covariance_length 36

  defstruct twist: %Twist{}, covariance: List.duplicate(0.0, @covariance_length)

  def covariance_length, do: @covariance_length

  def encode(%__MODULE__{twist: twist, covariance: covariance}) do
    Twist.encode(twist) <> encode_float64_array_fixed(covariance, @covariance_length)
  end
end
