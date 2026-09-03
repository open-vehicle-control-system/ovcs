defmodule Ros2.FoxgloveMsgs.Msg.PointsAnnotation do
  @moduledoc """
  `foxglove_msgs/PointsAnnotation` — a polyline or point set drawn on
  an image. Field order on the wire:

      builtin_interfaces/Time timestamp
      uint8 type
      foxglove_msgs/Point2[] points
      foxglove_msgs/Color outline_color
      foxglove_msgs/Color[] outline_colors
      foxglove_msgs/Color fill_color
      float64 thickness
      foxglove_msgs/KeyValuePair[] metadata

  `LINE_LOOP` is what a detection box wants: it closes the shape, so a
  rectangle is four points rather than the eight a `LINE_LIST` of
  segment pairs needs.

  `append_to/2` — `points` opens a `float64` run, and this struct is
  always nested inside an `ImageAnnotations` sequence, so it never
  starts at the body origin.
  """
  use Ros2.Common

  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.FoxgloveMsgs.Msg.{Color, Point2}

  @unknown 0
  @points 1
  @line_loop 2
  @line_strip 3
  @line_list 4

  def unknown, do: @unknown
  def points_type, do: @points
  def line_loop, do: @line_loop
  def line_strip, do: @line_strip
  def line_list, do: @line_list

  defstruct timestamp: %Time{},
            type: @line_loop,
            points: [],
            outline_color: %Color{},
            outline_colors: [],
            fill_color: %Color{a: 0.0},
            thickness: 1.0,
            metadata: []

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{} = annotation) when is_binary(buffer) do
    buffer
    |> Kernel.<>(Time.encode(annotation.timestamp))
    |> Kernel.<>(encode_uint8(annotation.type))
    # uint8 -> the u32 sequence count.
    |> align_to(4)
    |> append_points(annotation.points)
    # Color is float64 here, not float32 as in std_msgs/ColorRGBA.
    |> align_to(8)
    |> Kernel.<>(Color.encode(annotation.outline_color))
    |> append_colours(annotation.outline_colors)
    |> align_to(8)
    |> Kernel.<>(Color.encode(annotation.fill_color))
    |> Kernel.<>(encode_float64(annotation.thickness))
    # metadata: always empty here, so just the zero count.
    |> Kernel.<>(encode_uint32(length(annotation.metadata)))
  end

  defp append_points(buffer, []), do: buffer <> encode_uint32(0)

  defp append_points(buffer, points) do
    Enum.reduce(points, align_to(buffer <> encode_uint32(length(points)), 8), fn point, acc ->
      acc <> Point2.encode(point)
    end)
  end

  defp append_colours(buffer, []), do: buffer <> encode_uint32(0)

  defp append_colours(buffer, colours) do
    Enum.reduce(colours, align_to(buffer <> encode_uint32(length(colours)), 8), fn colour, acc ->
      acc <> Color.encode(colour)
    end)
  end
end
