defmodule Ros2.SensorMsgs.Msg.Image do
  @moduledoc """
  ROS 2 `sensor_msgs/Image`. Field order on the wire (per the IDL):

      Header header
      uint32 height
      uint32 width
      string encoding         # e.g. "mono16", "32FC1", "rgb8"
      uint8  is_bigendian
      uint32 step             # bytes per row (width × channels × depth)
      uint8[] data            # raw pixel bytes, row-major

  CDR alignment notes (relative to the start of the body):

    * After `Header` the tail is 4-aligned (its frame_id string
      pads to a 4-byte boundary via `encode_string/1`).
      `height`/`width` are u32s, naturally 4-aligned — fine.
    * `encoding` is followed by `is_bigendian` (u8, alignment 1)
      — so we must NOT pad after the string. The default
      `encode_string/1` would over-pad and shift every following
      field by 1–3 bytes on the receiver. We use
      `encode_string_unaligned/1` instead.
    * After `is_bigendian` we `align_to(buffer, 4)` to bring the
      tail up to a 4-aligned offset for `step`'s u32.
    * `step` (u32) is 4-aligned. The byte-sequence `data` follows
      with its own u32 length prefix (already 4-aligned) and then
      raw u8 bytes (no further alignment).

  `parse/1` exists because the bridge now *consumes* images too: a
  simulated camera in Gazebo publishes raw `sensor_msgs/Image`, and
  `RosBridge.Camera.Zenoh` turns those into the same frames a physical
  camera driver produces.

  Parsing has to undo the same two irregularities the encoder
  introduces — the unpadded `encoding` string, and the realignment
  after `is_bigendian` — and the second of those depends on the offset
  from the **body origin**, not from the start of what is left to
  parse. That is why `parse/1` takes the whole body and tracks its
  position through it.
  """
  use Ros2.Common

  alias Ros2.StdMsgs.Msg.Header

  defstruct [:header, height: 0, width: 0, encoding: "mono16",
             is_bigendian: 0, step: 0, data: <<>>]

  # Captured against ROS 2 Jazzy via `ros2 topic info -v` on an
  # rclpy publisher of `sensor_msgs/Image`. Refresh on distro bumps.
  @dds_type "sensor_msgs::msg::dds_::Image_"
  @type_hash "RIHS01_d31d41a9a4c4bc8eae9be757b0beed306564f7526c88ea6a4588fb9582527d47"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  @doc """
  Parse a `sensor_msgs/Image` body (no encapsulation header — 
  `Ros2.RmwZenoh.decode_payload/1` strips that).
  """
  def parse(body) when is_binary(body) do
    with {:ok, header, rest} <- Header.parse(body),
         <<height::little-unsigned-32, width::little-unsigned-32, rest::binary>> <- rest,
         # `encoding` was written without trailing padding, so it must
         # be read without skipping any.
         <<len::little-unsigned-32, encoding::binary-size(len), rest::binary>> <- rest,
         <<is_bigendian::little-unsigned-8, rest::binary>> <- rest,
         rest = consume_alignment(rest, 4, byte_size(body) - byte_size(rest)),
         <<step::little-unsigned-32, rest::binary>> <- rest,
         <<data_length::little-unsigned-32, rest::binary>> <- rest,
         <<data::binary-size(data_length), rest::binary>> <- rest do
      {:ok,
       %__MODULE__{
         header: header,
         height: height,
         width: width,
         encoding: String.trim_trailing(encoding, <<0>>),
         is_bigendian: is_bigendian,
         step: step,
         data: data
       }, rest}
    else
      _ -> {:error, :malformed, __MODULE__}
    end
  end

  def encode(%__MODULE__{} = image) do
    Header.encode(image.header)
    |> Kernel.<>(encode_uint32(image.height))
    |> Kernel.<>(encode_uint32(image.width))
    |> Kernel.<>(encode_string_unaligned(image.encoding))
    |> Kernel.<>(encode_uint8(image.is_bigendian))
    |> align_to(4)
    |> Kernel.<>(encode_uint32(image.step))
    |> Kernel.<>(encode_byte_sequence(image.data))
  end
end
