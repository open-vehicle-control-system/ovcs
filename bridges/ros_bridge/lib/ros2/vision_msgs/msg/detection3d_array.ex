defmodule Ros2.VisionMsgs.Msg.Detection3DArray do
  @moduledoc """
  ROS 2 `vision_msgs/Detection3DArray`: a `Header` and an unbounded
  sequence of `Detection3D`.

  This is the machine-readable half of what the detector publishes.
  Foxglove's 3D panel does **not** render it — that is what the
  parallel `visualization_msgs/MarkerArray` is for — but it is the
  message a downstream consumer such as nav2 expects, and it carries
  the class labels, scores and covariance that markers cannot.
  """
  use Ros2.Common

  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.VisionMsgs.Msg.Detection3D

  defstruct header: nil, detections: []

  def dds_type, do: "vision_msgs::msg::dds_::Detection3DArray_"

  def type_hash,
    do: "RIHS01_793f5eab9595ac1c0da07873cc859db42eae51f0ee76056db8562515d830e018"

  def encode(%__MODULE__{header: header, detections: detections}) do
    Enum.reduce(
      detections,
      Header.encode(header) <> encode_uint32(length(detections)),
      fn detection, acc ->
        # Each Detection3D opens with a Time, alignment 4.
        Detection3D.append_to(align_to(acc, 4), detection)
      end
    )
  end
end
