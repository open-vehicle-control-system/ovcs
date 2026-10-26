defmodule Ros2.NavMsgs.Msg.Path do
  @moduledoc """
  ROS 2 `nav_msgs/Path`: a `Header`, then a sequence of
  `geometry_msgs/PoseStamped`. Each pose is appended against the body
  origin, since its alignment depends on where the previous one ended.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.PoseStamped
  alias Ros2.StdMsgs.Msg.Header

  defstruct header: nil, poses: []

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
  @dds_type "nav_msgs::msg::dds_::Path_"
  @type_hash "RIHS01_1957a5bb3cee5da65c4e52e52b65a93df227efce4c20f8458b36e73066ca334b"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{header: header, poses: poses}) do
    buffer =
      Header.encode(header)
      |> align_to(4)
      |> Kernel.<>(encode_uint32(length(poses)))

    Enum.reduce(poses, buffer, &PoseStamped.append_to(&2, &1))
  end
end
