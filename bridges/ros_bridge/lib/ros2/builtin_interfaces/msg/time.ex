defmodule Ros2.BuiltinInterfaces.Msg.Time do
  @moduledoc """
  ROS 2 `builtin_interfaces/Time`: two consecutive 32-bit fields
  (`sec` int32, `nanosec` uint32), 8 bytes total, no CDR alignment
  padding inside the struct. The CDR encapsulation header is the
  caller's responsibility — it's stripped by
  `Ros2.RmwZenoh.decode_payload/1` upstream of any `parse/1` call.
  """
  use Ros2.Common

  defstruct sec: 0, nanosec: 0

  def encode(%__MODULE__{sec: sec, nanosec: nanosec}) do
    encode_int32(sec) <> encode_uint32(nanosec)
  end

  def parse(<<
        sec::little-signed-integer-size(32),
        nanosec::little-unsigned-integer-size(32),
        rest::binary
      >>) do
    {:ok, %__MODULE__{sec: sec, nanosec: nanosec}, rest}
  rescue
    _ -> {:error, :malformed, __MODULE__}
  end
end
