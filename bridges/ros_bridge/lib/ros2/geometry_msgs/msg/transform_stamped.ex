defmodule Ros2.GeometryMsgs.Msg.TransformStamped do
  @moduledoc """
  ROS 2 `geometry_msgs/TransformStamped`: a `Header`, the
  `child_frame_id` string, then the `Transform`.

  Exposes `append_to/2` rather than `encode/1` on purpose. CDR aligns
  each primitive relative to the **body origin**, not to the start of
  the struct being encoded, and `Transform` opens with a `float64`
  that must land on an 8-boundary. Nested inside `TFMessage` this
  struct begins at offset 4 (after the sequence length), so aligning a
  buffer that starts at 0 computes padding for the wrong offset — the
  message then encodes four bytes short and the receiver reports
  "Not enough memory in the buffer stream" while decoding.

  Taking the accumulated buffer means `align_to/2` sees the real
  offset. Callers must pass everything encoded so far.
  """
  use Ros2.Common

  alias Ros2.GeometryMsgs.Msg.Transform
  alias Ros2.StdMsgs.Msg.Header

  defstruct header: nil, child_frame_id: "", transform: %Transform{}

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{
        header: header,
        child_frame_id: child_frame_id,
        transform: transform
      })
      when is_binary(buffer) do
    (buffer <> Header.encode(header) <> encode_string(child_frame_id))
    |> align_to(8)
    |> Kernel.<>(Transform.encode(transform))
  end
end
