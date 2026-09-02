defmodule Ros2.Tf2Msgs.Msg.TFMessage do
  @moduledoc """
  ROS 2 `tf2_msgs/TFMessage`: an unbounded sequence of
  `geometry_msgs/TransformStamped`. This is what `/tf` carries, and
  without it a viewer has no transform tree — Foxglove's 3D panel
  cannot place a point cloud (or anything else) in space, and reports
  the frame as missing.

  Published on `/tf` rather than `/tf_static` deliberately. Static
  transforms conventionally use TRANSIENT_LOCAL durability so late
  joiners receive the one-shot latched message; `ZenohClient` publishes
  volatile, so a viewer connecting afterwards would never see it.
  Republishing on `/tf` at a low rate sidesteps durability entirely and
  costs a few hundred bytes a second.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.TransformStamped

  defstruct transforms: []

  # `ros2 topic info -v /tf` on a Jazzy node. Per-distro — re-check it
  # if the distro moves, exactly as for every other message here.
  def dds_type, do: "tf2_msgs::msg::dds_::TFMessage_"

  def type_hash,
    do: "RIHS01_e369d0f05a23ae52508854b66f6aa0437f3449d652e8cbf22d5abe85d020f087"

  def encode(%__MODULE__{transforms: transforms}) do
    # CDR sequence: uint32 count, then the elements. Each element is
    # appended to the running buffer rather than encoded standalone,
    # because TransformStamped aligns its Transform to 8 bytes
    # relative to the body origin — and after the 4-byte count that
    # offset is not what a struct-local encode would compute.
    Enum.reduce(transforms, encode_uint32(length(transforms)), fn transform, acc ->
      TransformStamped.append_to(acc, transform)
    end)
  end
end
