defmodule Ros2Zenoh.VisionMsgs.Msg.Detection2DArray do
  @moduledoc """
  ROS 2 `vision_msgs/Detection2DArray`: a `Header` and an unbounded
  sequence of `Detection2D`, boxes in an image's pixels: what a detector
  publishes of the objects it cannot place in 3D.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.VisionMsgs.Msg.Detection2D

  defstruct header: nil, detections: []

  def dds_type, do: "vision_msgs::msg::dds_::Detection2DArray_"

  def type_hash,
    do: "RIHS01_214274120007f4a683866481336b70310268cfa107aebe9d594a6acf75bda968"

  def encode(%__MODULE__{header: header, detections: detections}) do
    Enum.reduce(
      detections,
      Header.encode(header) <> encode_uint32(length(detections)),
      # Each Detection2D opens with a Time, alignment 4.
      fn detection, acc -> Detection2D.append_to(align_to(acc, 4), detection) end
    )
  end
end
