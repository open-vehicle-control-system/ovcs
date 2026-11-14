defmodule Ros2Zenoh.VisualizationMsgs.Msg.UVCoordinate do
  @moduledoc """
  ROS 2 `visualization_msgs/UVCoordinate`: two `float32`s, 8 bytes,
  alignment 4. Only meaningful for textured `TRIANGLE_LIST` markers;
  we publish an empty sequence.
  """
  use Ros2Zenoh.Common

  defstruct u: 0.0, v: 0.0

  def msg_definition do
    """
    # Location of the pixel as a ratio of the width of a 2D texture.
    # Values should be in range: [0.0-1.0].
    float32 u
    float32 v
    """
  end

  def dependencies, do: []

  def encode(%__MODULE__{u: u, v: v}) do
    encode_float32(u) <> encode_float32(v)
  end
end
