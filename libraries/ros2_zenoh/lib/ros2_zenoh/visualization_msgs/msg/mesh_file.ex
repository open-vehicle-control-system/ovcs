defmodule Ros2Zenoh.VisualizationMsgs.Msg.MeshFile do
  @moduledoc """
  ROS 2 `visualization_msgs/MeshFile`: a `filename` string and the
  embedded file `data` as `uint8[]`. Both fields are 4-aligned on
  entry and the byte run has alignment 1, so this adds no padding.

  We always publish it empty — it exists because `Marker` carries the
  field unconditionally, and CDR has no notion of an absent field.
  """
  use Ros2Zenoh.Common

  defstruct filename: "", data: <<>>

  def msg_definition do
    """
    # Used to send raw mesh files.

    # The filename is used for both debug purposes and to provide a file extension
    # for whatever parser is used.
    string filename

    # This stores the raw text of the mesh file.
    uint8[] data
    """
  end

  def dependencies, do: []

  def encode(%__MODULE__{filename: filename, data: data}) do
    encode_string(filename) <> encode_byte_sequence(data)
  end
end
