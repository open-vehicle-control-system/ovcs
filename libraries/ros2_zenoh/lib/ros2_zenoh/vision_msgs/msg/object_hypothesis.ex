defmodule Ros2Zenoh.VisionMsgs.Msg.ObjectHypothesis do
  @moduledoc """
  ROS 2 `vision_msgs/ObjectHypothesis`: a `class_id` string and a
  `float64` score.

  `class_id` is a free-form string, not an index — nav2 and the rest
  of the ROS ecosystem expect a label, so we publish the COCO class
  name rather than the integer the network emits.

  Needs `append_to/2`: `score` is a `float64` following a string, so
  the 8-alignment depends on where the struct starts.
  """
  use Ros2Zenoh.Common

  defstruct class_id: "", score: 0.0

  def msg_definition do
    """
    # An object hypothesis that contains no pose information.
    # If you would like to define an array of ObjectHypothesis messages,
    #   please see the Classification message type.

    # The unique ID of the object class. To get additional information about
    #   this ID, such as its human-readable class name, listeners should perform a
    #   lookup in a metadata database. See vision_msgs/VisionInfo.msg for more detail.
    string class_id

    # The probability or confidence value of the detected object. By convention,
    #   this value should lie in the range [0-1].
    float64 score
    """
  end

  def dependencies, do: []

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{class_id: class_id, score: score})
      when is_binary(buffer) do
    (buffer <> encode_string(class_id))
    |> align_to(8)
    |> Kernel.<>(encode_float64(score))
  end
end
