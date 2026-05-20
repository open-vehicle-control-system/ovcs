defmodule Ros2.SensorMsgs.Msg.CompressedImage do
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
  use Ros2.Common

  alias Ros2.StdMsgs.Msg.Header

  defstruct [:header, format: "jpeg", data: <<>>]

  # Hash captured against ROS 2 Jazzy via `ros2 topic info -v` on an
  # rclpy publisher of `sensor_msgs/CompressedImage`. Refresh on
  # distro bumps.
  @dds_type "sensor_msgs::msg::dds_::CompressedImage_"
  @type_hash "RIHS01_15640771531571185e2efc8a100baf923961a4d15d5569652e6cb6691e8e371a"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{} = msg) do
    Header.encode(msg.header)
    |> Kernel.<>(encode_string(msg.format))
    |> Kernel.<>(encode_byte_sequence(msg.data))
  end

  def parse(payload) do
    with {:ok, header, payload} <- Header.parse(payload),
         {:ok, format, payload} <- parse_string(payload),
         <<len::little-unsigned-integer-size(32), payload::binary>> <- payload,
         <<data::binary-size(len), payload::binary>> <- payload do
      {:ok, %__MODULE__{header: header, format: format, data: data}, payload}
    else
      _ -> {:error, :malformed, __MODULE__}
    end
  end
end
