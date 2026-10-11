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

  alias Ros2.GeometryMsgs.Msg.{
    Point,
    Pose,
    PoseWithCovariance,
    Quaternion,
    Twist,
    TwistWithCovariance
  }

  alias Ros2.StdMsgs.Msg.Header

  defstruct header: nil,
            child_frame_id: "",
            pose: %PoseWithCovariance{},
            twist: %TwistWithCovariance{}

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
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

  def parse(body) when is_binary(body) do
    with {:ok, header, rest} <- Header.parse(body),
         {:ok, child_frame_id, rest} <- parse_string(rest),
         # Alignment is computed against the body origin, not against
         # the start of this struct.
         rest = consume_alignment(rest, 8, byte_size(body) - byte_size(rest)),
         {:ok, [x, y, z], rest} <- parse_float64_array(rest, 3),
         {:ok, orientation, rest} <- Quaternion.parse(rest),
         {:ok, pose_covariance, rest} <- parse_float64_array(rest, 36),
         {:ok, twist, rest} <- Twist.parse(rest),
         {:ok, twist_covariance, rest} <- parse_float64_array(rest, 36) do
      {:ok,
       %__MODULE__{
         header: header,
         child_frame_id: child_frame_id,
         pose: %PoseWithCovariance{
           pose: %Pose{position: %Point{x: x, y: y, z: z}, orientation: orientation},
           covariance: pose_covariance
         },
         twist: %TwistWithCovariance{twist: twist, covariance: twist_covariance}
       }, rest}
    end
  end
end
