defmodule Ros2.VisualizationMsgs.Msg.MarkerArray do
  @moduledoc """
  ROS 2 `visualization_msgs/MarkerArray`: an unbounded sequence of
  `Marker`. This is the message Foxglove's 3D panel renders for
  detections — `vision_msgs/Detection3DArray` is *not* on the panel's
  supported list, so publishing only that would put the data on the
  wire with nothing to draw it.

  Each marker is appended to the running buffer rather than encoded
  standalone, because `Marker` aligns its `pose` to 8 bytes relative
  to the body origin. After the 4-byte count — and after every
  preceding marker, whose length varies with its strings — that
  offset is not what a struct-local encode would compute.

  How much this matters is easy to understand and easy to get wrong.
  A marker serialised on its own is 249 bytes; the same marker inside
  an array is 245, because starting at offset 4 leaves `action`
  ending on an 8-boundary and so needs no padding before `pose` at
  all. Between elements CDR then pads to 4, the alignment of the
  `Time` that opens the next marker's header.

  Those two effects cancel almost exactly, which is the trap: an
  encoder that pads neither produces an array of *precisely the right
  total length* whose every element after the first is misaligned.
  The only symptom is the receiver reporting "Not enough memory in
  the buffer stream", so length is not evidence of correctness here —
  the test deserialises with ROS instead.
  """
  use Ros2.Common

  alias Ros2.VisualizationMsgs.Msg.Marker

  defstruct markers: []

  def dds_type, do: "visualization_msgs::msg::dds_::MarkerArray_"

  def type_hash,
    do: "RIHS01_86cb8800b6fb05b5eff1abd7a56f62a5641d3ae9a1c29e78e67e704f1d067dcf"

  def encode(%__MODULE__{markers: markers}) do
    Enum.reduce(markers, encode_uint32(length(markers)), fn marker, acc ->
      # `Marker` opens with a `Time`, whose int32 wants a 4-boundary.
      Marker.append_to(align_to(acc, 4), marker)
    end)
  end
end
