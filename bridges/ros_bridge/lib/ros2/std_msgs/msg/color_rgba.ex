defmodule Ros2.StdMsgs.Msg.ColorRGBA do
  @moduledoc """
  ROS 2 `std_msgs/ColorRGBA`: four `float32`s in 0.0..1.0, 16 bytes.
  Alignment 4, so it needs no padding after any u32-aligned field.

  Note `a` defaults to 1.0 rather than 0.0: a marker published with
  the struct default of a fully transparent colour renders as
  nothing at all, which is indistinguishable from a broken pipeline.
  """
  use Ros2.Common

  defstruct r: 0.0, g: 0.0, b: 0.0, a: 1.0

  def encode(%__MODULE__{r: r, g: g, b: b, a: a}) do
    encode_float32(r) <> encode_float32(g) <> encode_float32(b) <> encode_float32(a)
  end
end
