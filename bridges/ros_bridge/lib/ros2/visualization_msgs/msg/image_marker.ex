defmodule Ros2.VisualizationMsgs.Msg.ImageMarker do
  @moduledoc """
  ROS 2 `visualization_msgs/ImageMarker` — the 2D annotation Foxglove's
  **Image** panel overlays on a camera image. Field order on the wire:

      std_msgs/Header header
      string ns
      int32 id
      int32 type
      int32 action
      geometry_msgs/Point position
      float32 scale
      std_msgs/ColorRGBA outline_color
      uint8 filled
      std_msgs/ColorRGBA fill_color
      builtin_interfaces/Duration lifetime
      geometry_msgs/Point[] points
      std_msgs/ColorRGBA[] outline_colors

  Points are **pixel coordinates**, not metres — this is an image
  overlay, and `z` is unused.

  ## One message, many boxes

  ROS 2 has no `ImageMarkerArray` (it is not in Jazzy's
  `visualization_msgs`), and the Image panel takes one message per
  annotation topic. Drawing N detections would therefore need N
  topics, which is unworkable.

  `LINE_LIST` is the way out: it draws `points` as independent pairs,
  so a rectangle is four pairs — eight points — and any number of
  boxes fits in a single marker. `outline_colors` then carries one
  colour per point, which is what lets each box keep its own
  score-derived colour in a shared message.

  ## Alignment

  Two hazards, both the usual kind:

    * `action` (int32) is followed by `position`, which opens on a
      `float64` — `align_to(8)`.
    * `filled` is a `uint8` followed by `fill_color`'s `float32`s —
      `align_to(4)`.

  `append_to/2` rather than `encode/1` for the reason documented on
  `TransformStamped`: alignment is relative to the body origin, so a
  struct that might ever be nested cannot compute its own padding.
  """
  use Ros2.Common

  alias Ros2.BuiltinInterfaces.Msg.Duration
  alias Ros2.GeometryMsgs.Msg.Point
  alias Ros2.StdMsgs.Msg.{ColorRGBA, Header}

  @circle 0
  @line_strip 1
  @line_list 2
  @polygon 3
  @points 4

  @add 0
  @remove 1

  def circle, do: @circle
  def line_strip, do: @line_strip
  def line_list, do: @line_list
  def polygon, do: @polygon
  def points, do: @points

  def add, do: @add
  def remove, do: @remove

  defstruct header: nil,
            ns: "",
            id: 0,
            type: @line_list,
            action: @add,
            position: %Point{},
            scale: 1.0,
            outline_color: %ColorRGBA{},
            filled: 0,
            fill_color: %ColorRGBA{a: 0.0},
            lifetime: %Duration{},
            points: [],
            outline_colors: []

  def dds_type, do: "visualization_msgs::msg::dds_::ImageMarker_"

  def type_hash,
    do: "RIHS01_603152491ef2331c200a5305230d31f6e8704875944b388da0f547c415d11836"

  @spec append_to(binary(), %__MODULE__{}) :: binary()
  def append_to(buffer, %__MODULE__{} = marker) when is_binary(buffer) do
    buffer
    |> Kernel.<>(Header.encode(marker.header))
    |> Kernel.<>(encode_string(marker.ns))
    |> Kernel.<>(encode_int32(marker.id))
    |> Kernel.<>(encode_int32(marker.type))
    |> Kernel.<>(encode_int32(marker.action))
    # position opens on a float64.
    |> align_to(8)
    |> Kernel.<>(Point.encode(marker.position))
    |> Kernel.<>(encode_float32(marker.scale))
    |> Kernel.<>(ColorRGBA.encode(marker.outline_color))
    |> Kernel.<>(encode_uint8(marker.filled))
    # uint8 (alignment 1) -> float32.
    |> align_to(4)
    |> Kernel.<>(ColorRGBA.encode(marker.fill_color))
    |> Kernel.<>(Duration.encode(marker.lifetime))
    |> append_point_sequence(marker.points)
    |> append_colour_sequence(marker.outline_colors)
  end

  def encode(%__MODULE__{} = marker), do: append_to(<<>>, marker)

  defp append_point_sequence(buffer, []), do: buffer <> encode_uint32(0)

  defp append_point_sequence(buffer, points) do
    Enum.reduce(points, align_to(buffer <> encode_uint32(length(points)), 8), fn point, acc ->
      acc <> Point.encode(point)
    end)
  end

  # ColorRGBA is float32 throughout, so the u32 count already leaves
  # the buffer where the elements need it.
  defp append_colour_sequence(buffer, colours) do
    Enum.reduce(colours, buffer <> encode_uint32(length(colours)), fn colour, acc ->
      acc <> ColorRGBA.encode(colour)
    end)
  end
end
