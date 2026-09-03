defmodule Ros2.VisualizationMsgs.Msg.UVCoordinate do
  @moduledoc """
  ROS 2 `visualization_msgs/UVCoordinate`: two `float32`s, 8 bytes,
  alignment 4. Only meaningful for textured `TRIANGLE_LIST` markers;
  we publish an empty sequence.
  """
  use Ros2.Common

  defstruct u: 0.0, v: 0.0

  def encode(%__MODULE__{u: u, v: v}) do
    encode_float32(u) <> encode_float32(v)
  end
end
