defmodule Ros2.VisionMsgs.Msg.Detection3D do
  @moduledoc """
  ROS 2 `vision_msgs/Detection3D`. Field order on the wire:

      std_msgs/Header header
      ObjectHypothesisWithPose[] results
      BoundingBox3D bbox
      string id

  `append_to/2` for the usual reason — `bbox` opens on a `float64`,
  and nested in a `Detection3DArray` this struct does not start at
  the body origin.
  """
  use Ros2.Common

  alias Ros2.StdMsgs.Msg.Header
  alias Ros2.VisionMsgs.Msg.{BoundingBox3D, ObjectHypothesisWithPose}

  defstruct header: nil, results: [], bbox: %BoundingBox3D{}, id: ""

  def dds_type, do: "vision_msgs::msg::dds_::Detection3D_"

  def type_hash,
    do: "RIHS01_ddd703be132ab0b69d33121f1bb034132bfbb3b0ac5f9fb1516005ba1c8a265b"

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{} = detection) when is_binary(buffer) do
    buffer
    |> Kernel.<>(Header.encode(detection.header))
    |> append_results(detection.results)
    |> align_to(8)
    |> Kernel.<>(BoundingBox3D.encode(detection.bbox))
    # `id` is the final field, and CDR pads only on behalf of a
    # *following* field's alignment — so the padded `encode_string/1`
    # would make every detection two bytes too long. When this struct
    # is nested, the array encoder re-aligns before the next element.
    |> Kernel.<>(encode_string_unaligned(detection.id))
  end

  defp append_results(buffer, results) do
    Enum.reduce(results, buffer <> encode_uint32(length(results)), fn result, acc ->
      # Each element opens with a string (u32 length), alignment 4.
      ObjectHypothesisWithPose.append_to(align_to(acc, 4), result)
    end)
  end
end
