defmodule Ros2Zenoh.VisionMsgs.Msg.Detection3D do
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
  use Ros2Zenoh.Common

  alias Ros2Zenoh.StdMsgs.Msg.Header
  alias Ros2Zenoh.VisionMsgs.Msg.{BoundingBox3D, ObjectHypothesisWithPose}

  defstruct header: nil, results: [], bbox: %BoundingBox3D{}, id: ""

  def msg_definition do
    """
    # Defines a 3D detection result.
    #
    # This extends a basic 3D classification by including the pose of the
    # detected object.

    std_msgs/Header header

    # Class probabilities. Does not have to include hypotheses for all possible
    #   object ids, the scores for any ids not listed are assumed to be 0.
    ObjectHypothesisWithPose[] results

    # 3D bounding box surrounding the object.
    BoundingBox3D bbox

    # ID used for consistency across multiple detection messages. Detections
    # of the same object in different detection messages should have the same id.
    # This field may be empty.
    string id

    # Source data that generated this classification are not a part of the message.
    # If you need to access them, use an exact or approximate time synchronizer in
    # your code, as this message's header should match the header of the source
    # data.
    """
  end

  def dependencies,
    do: [
      Header,
      ObjectHypothesisWithPose,
      BoundingBox3D
    ]

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
    # CDR pads only for a following field, and `id` is last; the array
    # encoder re-aligns before the next element.
    |> Kernel.<>(encode_string_unaligned(detection.id))
  end

  defp append_results(buffer, results) do
    Enum.reduce(results, buffer <> encode_uint32(length(results)), fn hypothesis, acc ->
      # Each element opens with a string (u32 length), alignment 4.
      ObjectHypothesisWithPose.append_to(align_to(acc, 4), hypothesis)
    end)
  end
end
