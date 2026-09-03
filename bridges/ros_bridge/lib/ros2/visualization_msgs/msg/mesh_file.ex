defmodule Ros2.VisualizationMsgs.Msg.MeshFile do
  @moduledoc """
  ROS 2 `visualization_msgs/MeshFile`: a `filename` string and the
  embedded file `data` as `uint8[]`. Both fields are 4-aligned on
  entry and the byte run has alignment 1, so this adds no padding.

  We always publish it empty — it exists because `Marker` carries the
  field unconditionally, and CDR has no notion of an absent field.
  """
  use Ros2.Common

  defstruct filename: "", data: <<>>

  def encode(%__MODULE__{filename: filename, data: data}) do
    encode_string(filename) <> encode_byte_sequence(data)
  end
end
