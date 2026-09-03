defmodule Ros2.FoxgloveMsgs.Msg.ImageAnnotations do
  @moduledoc """
  `foxglove_msgs/ImageAnnotations` — the 2D overlay Foxglove's Image
  panel draws on a camera stream. Field order on the wire:

      builtin_interfaces/Time timestamp
      foxglove_msgs/CircleAnnotation[] circles
      foxglove_msgs/PointsAnnotation[] points
      foxglove_msgs/TextAnnotation[] texts
      foxglove_msgs/KeyValuePair[] metadata

  Chosen over `visualization_msgs/ImageMarker` because it carries
  boxes *and* their labels in one message. `ImageMarker` has no text
  type at all, and ROS 2 has no `ImageMarkerArray`, so labelled boxes
  were not expressible with it.

  The cost is a dependency: `foxglove_msgs` is not part of a ROS base
  install, so `ros-jazzy-foxglove-msgs` is installed in
  `ros2/vehicule/image/Dockerfile` — without it `foxglove_bridge`
  cannot resolve the type and never advertises the topic.

  `circles` is always empty here; the field still has to be encoded,
  because CDR has no absent fields.
  """
  use Ros2.Common

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.FoxgloveMsgs.Msg.{PointsAnnotation, TextAnnotation}

  defstruct timestamp: %Time{}, circles: [], points: [], texts: [], metadata: []

  def dds_type, do: "foxglove_msgs::msg::dds_::ImageAnnotations_"

  def type_hash,
    do: "RIHS01_bc4e578b1ef80953415d6f966a4cab305c8a44c8b64fc405312b6f06a08fc45e"

  def encode(%__MODULE__{} = annotations) do
    Time.encode(annotations.timestamp)
    # circles: unused, but the count is still on the wire.
    |> Kernel.<>(encode_uint32(length(annotations.circles)))
    |> append_sequence(annotations.points, &PointsAnnotation.append_to/2)
    |> append_sequence(annotations.texts, &TextAnnotation.append_to/2)
    |> Kernel.<>(encode_uint32(length(annotations.metadata)))
  end

  # Each element opens with a Time, whose int32 wants a 4-boundary.
  defp append_sequence(buffer, values, append_one) do
    Enum.reduce(values, buffer <> encode_uint32(length(values)), fn value, acc ->
      append_one.(align_to(acc, 4), value)
    end)
  end
end
