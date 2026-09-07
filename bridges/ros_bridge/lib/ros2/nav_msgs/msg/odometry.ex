defmodule Ros2.NavMsgs.Msg.Odometry do
  @moduledoc """
  ROS 2 `nav_msgs/Odometry`. Field order on the wire (per the IDL):

      Header header
      string child_frame_id
      PoseWithCovariance pose
      TwistWithCovariance twist

  CDR alignment: the `Header` tail and the `child_frame_id` string
  both end 4-aligned, and `pose` opens with a `float64`, so the one
  hazard is the string → pose boundary, aligned to 8 against the body
  origin. Everything after is a float64 run.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.PoseWithCovariance
  alias Ros2.GeometryMsgs.Msg.TwistWithCovariance
  alias Ros2.StdMsgs.Msg.Header

  defstruct header: nil,
            child_frame_id: "",
            pose: %PoseWithCovariance{},
            twist: %TwistWithCovariance{}

  # rmw_zenoh keyexpr metadata for `nav_msgs/msg/Odometry`. The RIHS01
  # hash was captured against ROS 2 Lyrical (the distro Nav2 runs on
  # here) via `ros2 topic info -v /odom` on a `ros2 topic pub`
  # publisher, the same procedure as every other hash in this tree.
  # Refresh on distro bumps.
  @dds_type "nav_msgs::msg::dds_::Odometry_"
  @type_hash "RIHS01_3cc97dc7fb7502f8714462c526d369e35b603cfc34d946e3f2eda2766dfec6e0"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = odometry) do
    Header.encode(odometry.header)
    |> Kernel.<>(encode_string(odometry.child_frame_id))
    |> align_to(8)
    |> Kernel.<>(PoseWithCovariance.encode(odometry.pose))
    |> Kernel.<>(TwistWithCovariance.encode(odometry.twist))
  end
end
