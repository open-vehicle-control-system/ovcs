defmodule Ros2.FoxgloveMsgs.Msg.Color do
  @moduledoc """
  `foxglove_msgs/Color`: r, g, b, a as **float64** in 0.0..1.0.

  Note the width: `std_msgs/ColorRGBA` uses float32 for the same four
  fields, and mixing them up shifts every field after the colour.
  """
  use Ros2.Common

  defstruct r: 0.0, g: 0.0, b: 0.0, a: 1.0

  def encode(%__MODULE__{r: r, g: g, b: b, a: a}) do
    encode_float64(r) <> encode_float64(g) <> encode_float64(b) <> encode_float64(a)
  end
end
