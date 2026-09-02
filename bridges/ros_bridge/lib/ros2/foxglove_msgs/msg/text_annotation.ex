defmodule Ros2.FoxgloveMsgs.Msg.TextAnnotation do
  @moduledoc """
  `foxglove_msgs/TextAnnotation` — a text label drawn at a pixel
  position on an image. Field order on the wire:

      builtin_interfaces/Time timestamp
      foxglove_msgs/Point2 position
      string text
      float64 font_size
      foxglove_msgs/Color text_color
      foxglove_msgs/Color background_color
      foxglove_msgs/KeyValuePair[] metadata

  This is the reason the overlay uses `foxglove_msgs` at all:
  `visualization_msgs/ImageMarker` has no text type, so a box drawn
  with it can never say what it is.
  """
  use Ros2.Common

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.FoxgloveMsgs.Msg.{Color, Point2}

  defstruct timestamp: %Time{},
            position: %Point2{},
            text: "",
            font_size: 12.0,
            text_color: %Color{r: 1.0, g: 1.0, b: 1.0, a: 1.0},
            background_color: %Color{a: 0.0},
            metadata: []

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{} = annotation) when is_binary(buffer) do
    buffer
    |> Kernel.<>(Time.encode(annotation.timestamp))
    # position opens a float64 run.
    |> align_to(8)
    |> Kernel.<>(Point2.encode(annotation.position))
    |> Kernel.<>(encode_string(annotation.text))
    # string tail is 4-aligned; font_size is a float64.
    |> align_to(8)
    |> Kernel.<>(encode_float64(annotation.font_size))
    |> Kernel.<>(Color.encode(annotation.text_color))
    |> Kernel.<>(Color.encode(annotation.background_color))
    |> Kernel.<>(encode_uint32(length(annotation.metadata)))
  end
end
