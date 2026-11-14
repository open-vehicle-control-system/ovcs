defmodule Ros2Zenoh.BuiltinInterfaces.Msg.Time do
  @moduledoc """
  ROS 2 `builtin_interfaces/Time`: two consecutive 32-bit fields
  (`sec` int32, `nanosec` uint32), 8 bytes total, no CDR alignment
  padding inside the struct. The CDR encapsulation header is the
  caller's responsibility — it's stripped by
  `Ros2Zenoh.RmwZenoh.decode_payload/1` upstream of any `parse/1` call.
  """
  use Ros2Zenoh.Common

  defstruct sec: 0, nanosec: 0

  def msg_definition do
    """
    # This message communicates ROS Time defined here:
    # https://design.ros2.org/articles/clock_and_time.html

    # The seconds component, valid over all int32 values.
    int32 sec

    # The nanoseconds component, valid in the range [0, 1e9), to be added to the seconds component.\s
    # e.g.
    # The time -1.7 seconds is represented as {sec: -2, nanosec: 3e8}
    # The time 1.7 seconds is represented as {sec: 1, nanosec: 7e8}
    uint32 nanosec
    """
  end

  def dependencies, do: []

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
