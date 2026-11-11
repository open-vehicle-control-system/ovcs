defmodule Ros2Zenoh.VisionMsgs.Msg.Detection2D do
  @moduledoc """
  ROS 2 `vision_msgs/Detection2D`. Field order on the wire:

      std_msgs/Header header
      ObjectHypothesisWithPose[] results
      BoundingBox2D bbox
      string id

  `append_to/2` as `Detection3D`'s: `bbox` opens on a `float64`, and
  nested in a `Detection2DArray` this struct does not start at the body
  origin.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.VisionMsgs.Msg.{BoundingBox2D, ObjectHypothesisWithPose}

  defstruct header: nil, results: [], bbox: %BoundingBox2D{}, id: ""

  def dds_type, do: "vision_msgs::msg::dds_::Detection2D_"

  def type_hash,
    do: "RIHS01_0d12b69df5c593b3455b7346fac8205437a7d4bcb09b9e0e0b2dde787ded38ea"

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{} = detection) when is_binary(buffer) do
    buffer
    |> Kernel.<>(Header.encode(detection.header))
    |> append_results(detection.results)
    |> align_to(8)
    |> Kernel.<>(BoundingBox2D.encode(detection.bbox))
    # `id` is last: the array encoder re-aligns before the next element.
    |> Kernel.<>(encode_string_unaligned(detection.id))
  end

  defp append_results(buffer, results) do
    Enum.reduce(results, buffer <> encode_uint32(length(results)), fn hypothesis, acc ->
      ObjectHypothesisWithPose.append_to(align_to(acc, 4), hypothesis)
    end)
  end
end
