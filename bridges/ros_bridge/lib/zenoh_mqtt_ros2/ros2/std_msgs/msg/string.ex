defmodule Ros2.StdMsgs.Msg.String do
  @moduledoc false
  use Ros2.Common

  defstruct data: ""

  # rmw_zenoh keyexpr metadata. The DDS-mangled type name comes from
  # rosidl's IDL convention. The type hash is the REP-2016 RIHS01
  # value for std_msgs/msg/String in ROS 2 Jazzy — verify from a live
  # node with `ros2 topic info -v <topic>` (the "Topic type hash"
  # line) and refresh this constant if you ever bump distros.
  @dds_type "std_msgs::msg::dds_::String_"
  @type_hash "RIHS01_df668c740482bbd48fb39d76a70dfd4bd59db1288021743503259e948f6b1a18"

  def dds_type, do: @dds_type
  def type_hash, do: @type_hash

  def encode(%__MODULE__{data: data}), do: encode_string(data)

  def parse(<<_sequence::little-unsigned-integer-32, payload::binary>>) do
    case parse_string(payload) do
      {:ok, string, payload} -> {:ok, %__MODULE__{data: string}, payload}
      error -> error
    end
  end
end
