defmodule Ros2.FoxgloveMsgs.Msg.Point2 do
  @moduledoc """
  `foxglove_msgs/Point2`: two `float64`s. In an image annotation these
  are **pixel** coordinates, not metres.
  """
  use Ros2.Common

  defstruct x: 0.0, y: 0.0

  def encode(%__MODULE__{x: x, y: y}), do: encode_float64(x) <> encode_float64(y)
end
