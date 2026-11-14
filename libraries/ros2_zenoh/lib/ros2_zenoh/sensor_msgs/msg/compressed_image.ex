defmodule Ros2Zenoh.SensorMsgs.Msg.CompressedImage do
  @moduledoc """
  ROS 2 `sensor_msgs/CompressedImage`. Field order on the wire:

      Header header
      string format       # e.g. "jpeg", "png"
      uint8[] data        # compressed bytes

  CDR alignment: Header's tail is 4-aligned via string padding,
  `format`'s string prefix is u32 (4-aligned, no padding needed),
  and `data`'s u32 length prefix is likewise 4-aligned. The u8 run
  itself has alignment 1 so no padding follows.
  """
  use Ros2Zenoh.Common

  alias Ros2Zenoh.StdMsgs.Msg.Header

  defstruct [:header, format: "jpeg", data: <<>>]

  def msg_definition do
    """
    # This message contains a compressed image.

    std_msgs/Header header # Header timestamp should be acquisition time of image
                                 # Header frame_id should be optical frame of camera
                                 # origin of frame should be optical center of cameara
                                 # +x should point to the right in the image
                                 # +y should point down in the image
                                 # +z should point into to plane of the image

    string format                # Specifies the format of the data
                                 # Acceptable values differ by the image transport used:
                                 # - compressed_image_transport:
                                 #     ORIG_PIXFMT; CODEC compressed [COMPRESSED_PIXFMT]
                                 #   where:
                                 #   - ORIG_PIXFMT is pixel format of the raw image, i.e.
                                 #     the content of sensor_msgs/Image/encoding with
                                 #     values from include/sensor_msgs/image_encodings.h
                                 #   - CODEC is one of [jpeg, png, tiff]
                                 #   - COMPRESSED_PIXFMT is only appended for color images
                                 #     and is the pixel format used by the compression
                                 #     algorithm. Valid values for jpeg encoding are:
                                 #     [bgr8, rgb8]. Valid values for png encoding are:
                                 #     [bgr8, rgb8, bgr16, rgb16].
                                 #   If the field is empty or does not correspond to the
                                 #   above pattern, the image is treated as bgr8 or mono8
                                 #   jpeg image (depending on the number of channels).
                                 # - compressed_depth_image_transport:
                                 #     ORIG_PIXFMT; compressedDepth CODEC
                                 #   where:
                                 #   - ORIG_PIXFMT is pixel format of the raw image, i.e.
                                 #     the content of sensor_msgs/Image/encoding with
                                 #     values from include/sensor_msgs/image_encodings.h
                                 #     It is usually one of [16UC1, 32FC1].
                                 #   - CODEC is one of [png, rvl]
                                 #   If the field is empty or does not correspond to the
                                 #   above pattern, the image is treated as png image.
                                 # - Other image transports can store whatever values they
                                 #   need for successful decoding of the image. Refer to
                                 #   documentation of the other transports for details.

    uint8[] data                 # Compressed image buffer
    """
  end

  def dependencies, do: [Header]

  # RIHS01 hash for ROS 2 Lyrical; it changes with the distro.
  @dds_type "sensor_msgs::msg::dds_::CompressedImage_"
  @type_hash "RIHS01_15640771531571185e2efc8a100baf923961a4d15d5569652e6cb6691e8e371a"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = compressed_image) do
    Header.encode(compressed_image.header)
    |> Kernel.<>(encode_string(compressed_image.format))
    |> Kernel.<>(encode_byte_sequence(compressed_image.data))
  end

  def parse(payload) do
    with {:ok, header, payload} <- Header.parse(payload),
         {:ok, format, payload} <- parse_string(payload),
         <<data_length::little-unsigned-integer-size(32), payload::binary>> <- payload,
         <<data::binary-size(^data_length), payload::binary>> <- payload do
      {:ok, %__MODULE__{header: header, format: format, data: data}, payload}
    else
      _ -> {:error, :malformed, __MODULE__}
    end
  end
end
