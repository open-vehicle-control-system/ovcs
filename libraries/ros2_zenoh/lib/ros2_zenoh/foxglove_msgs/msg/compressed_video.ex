defmodule Ros2Zenoh.FoxgloveMsgs.Msg.CompressedVideo do
  @moduledoc """
  `foxglove_msgs/CompressedVideo`, one frame of a compressed video
  stream, which Foxglove's Image panel decodes. Field order on the wire:

      builtin_interfaces/Time timestamp
      string frame_id
      uint8[] data        # the frame, for "h264" its NAL units in Annex B form
      string format       # "h264", "h265", "vp9" or "av1"

  `format` follows a byte run, so its length prefix re-aligns to 4; it
  ends the message, without trailing padding, as Fast-CDR writes it.
  Like `ImageAnnotations`, it needs `ros-<distro>-foxglove-msgs` on the
  ROS side.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Time

  defstruct timestamp: %Time{}, frame_id: "", data: <<>>, format: "h264"

  def dds_type, do: "foxglove_msgs::msg::dds_::CompressedVideo_"

  def type_hash,
    do: "RIHS01_32039eafc3770e589c86c4dabff9c392ce9955ebffd43f5f60763011d43d8d1d"

  def encode(%__MODULE__{} = video) do
    Time.encode(video.timestamp)
    |> Kernel.<>(encode_string(video.frame_id))
    |> Kernel.<>(encode_byte_sequence(video.data))
    |> align_to(4)
    |> Kernel.<>(encode_string_unaligned(video.format))
  end
end
