defmodule Ros2.VisionMsgs.Msg.ObjectHypothesis do
  @moduledoc """
  ROS 2 `vision_msgs/ObjectHypothesis`: a `class_id` string and a
  `float64` score.

  `class_id` is a free-form string, not an index — nav2 and the rest
  of the ROS ecosystem expect a label, so we publish the COCO class
  name rather than the integer the network emits.

  Needs `append_to/2`: `score` is a `float64` following a string, so
  the 8-alignment depends on where the struct starts.
  """
  use Ros2.Common

  defstruct class_id: "", score: 0.0

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{class_id: class_id, score: score})
      when is_binary(buffer) do
    (buffer <> encode_string(class_id))
    |> align_to(8)
    |> Kernel.<>(encode_float64(score))
  end
end
