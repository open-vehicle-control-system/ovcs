defmodule Ros2.GeometryMsgs.Msg.PoseStamped do
  @moduledoc """
  ROS 2 `geometry_msgs/PoseStamped`: a `Header`, then a `Pose`.

  `Pose` opens with a `float64` and the `Header` ends 4-aligned, so the
  pose is aligned to 8 against the body origin. Nested in a sequence,
  as in `nav_msgs/Path`, that origin is the enclosing message's: use
  `append_to/2` there rather than `encode/1`.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.Pose
  alias Ros2.StdMsgs.Msg.Header

  defstruct header: nil, pose: %Pose{}

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
  @dds_type "geometry_msgs::msg::dds_::PoseStamped_"
  @type_hash "RIHS01_10f3786d7d40fd2b54367835614bff85d4ad3b5dab62bf8bca0cc232d73b4cd8"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = pose_stamped), do: append_to(<<>>, pose_stamped)

  @doc "Appends `pose_stamped` to the in-progress body `buffer`, aligned against its origin."
  def append_to(buffer, %__MODULE__{header: header, pose: pose}) do
    buffer
    |> align_to(4)
    |> Kernel.<>(Header.encode(header))
    |> align_to(8)
    |> Kernel.<>(Pose.encode(pose))
  end
end
