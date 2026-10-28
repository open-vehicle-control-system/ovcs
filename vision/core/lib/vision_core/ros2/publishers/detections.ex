defmodule VisionCore.Ros2.Publishers.Detections do
  @moduledoc """
  Publishes the 3D detections of `VisionCore.Detection.Pipeline`: a
  `visualization_msgs/MarkerArray` (what Foxglove's 3D panel renders),
  a `vision_msgs/Detection3DArray` (what nav2 will consume), and a 2D
  overlay on the left raw image.

  ## Frames

  Everything is published in the depth image's own optical frame, so
  it lines up with the point cloud without further transformation.
  The vehicle's transform tree relates that frame to the vehicle body
  — without it a viewer has boxes but nowhere to put them.

  ## Options

    * `:topic_prefix` (`"stereo"`) — markers go to
      `<prefix>/detections/markers`, detections to
      `<prefix>/detections`, and the 2D image overlay to
      `<prefix>/left/detections`.
    * `:frame_id` (`"<prefix>_left"`) — must match the frame the
      stereo unit stamps its depth image with, since the boxes are
      positioned in that image's pixels.
    * `:marker_lifetime_ms` (`500`) — how long a marker survives
      without being refreshed. Longer than the frame interval so
      markers do not flicker, short enough that a stale box goes away
      promptly.
    * `:outline_segments` (`4`) — how finely each box edge is
      subdivided for the 2D overlay. See "Drawing on the raw image".
    * `:label_font_size` (`12.0`) — 2D overlay label size, in pixels.

  ## Drawing on the raw image

  The boxes are computed in *rectified* pixels, but the image the
  vision core publishes — and the one the Foxglove Image panel shows — is
  `image_raw`. The two differ by several pixels on a typical lens, so
  drawing rectified coordinates straight onto the raw image puts the
  box visibly beside the object.

  Rather than publish a second, rectified image stream, each outline
  vertex is mapped back through OpenCV's rectification map. A
  straight edge in rectified space is a curve in raw space, so edges
  are subdivided (`:outline_segments`) and each vertex mapped
  individually.

  The overlay is a `foxglove_msgs/ImageAnnotations` rather than a
  `visualization_msgs/ImageMarker`, because ImageMarker has no text
  type: a box drawn with it can never say what it is.
  """
  use GenServer

  require Logger

  alias Ros2Zenoh.BuiltinInterfaces.Msg.Duration
  alias Ros2Zenoh.GeometryMsgs.Msg.{Point, Pose, PoseWithCovariance, Quaternion, Vector3}
  alias Ros2Zenoh.StdMsgs.Msg.{ColorRGBA, Header}
  alias Ros2Zenoh.VisionMsgs.Msg.{BoundingBox3D, Detection3D, Detection3DArray}
  alias Ros2Zenoh.VisionMsgs.Msg.{ObjectHypothesis, ObjectHypothesisWithPose}

  alias Ros2Zenoh.FoxgloveMsgs.Msg.{
    Color,
    ImageAnnotations,
    Point2,
    PointsAnnotation,
    TextAnnotation
  }

  alias Ros2Zenoh.VisualizationMsgs.Msg.{Marker, MarkerArray}
  alias VisionCore.Detection.Fusion
  alias VisionCore.Ros2.Stamp
  alias VisionCore.Stereo.Pair

  @default_topic_prefix "stereo"
  @default_marker_lifetime_ms 500
  @default_outline_segments 4
  @default_label_font_size 12.0

  @namespace "detections"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    topic_prefix = Keyword.get(opts, :topic_prefix, @default_topic_prefix)

    state = %{
      markers_topic: "#{topic_prefix}/detections/markers",
      detections_topic: "#{topic_prefix}/detections",
      overlay_topic: "#{topic_prefix}/left/detections",
      frame_id: Keyword.get(opts, :frame_id, "#{topic_prefix}_left"),
      marker_lifetime:
        opts
        |> Keyword.get(:marker_lifetime_ms, @default_marker_lifetime_ms)
        |> Duration.from_milliseconds(),
      outline_segments: Keyword.get(opts, :outline_segments, @default_outline_segments),
      label_font_size: Keyword.get(opts, :label_font_size, @default_label_font_size),
      # Keyed on the Mat itself, so a calibration reload invalidates it.
      rectification_map_cache: nil,
      published_count: 0,
      # Detection indexes drawn last frame; those not redrawn get an explicit DELETE.
      previous_indexes: MapSet.new()
    }

    VisionCore.Detection.Pipeline.register_listener(VisionCore.Detection.Pipeline, self())

    Logger.info(
      "#{__MODULE__} publishing markers on #{state.markers_topic} and " <>
        "detections on #{state.detections_topic} (frame #{state.frame_id})"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:detections, %Pair{} = pair, detections}, state),
    do: {:noreply, publish(detections, pair, state)}

  def handle_cast(_message, state), do: {:noreply, state}

  defp publish(positioned, %Pair{} = pair, state) do
    stamp = Stamp.stamp_from_monotonic(Pair.capture_ns(pair))
    header = %Header{stamp: stamp, frame_id: state.frame_id}

    publish_markers(positioned, header, state)
    publish_detections(positioned, header, state)
    state = publish_overlay(positioned, header, pair, state)

    %{
      state
      | published_count: state.published_count + length(positioned),
        previous_indexes: MapSet.new(Enum.with_index(positioned), fn {_, index} -> index end)
    }
  end

  defp publish_markers(positioned, header, state) do
    markers =
      positioned
      |> Enum.with_index()
      |> Enum.flat_map(fn {detection, index} ->
        [
          box_marker(detection, index, header, state),
          label_marker(detection, index, header, state)
        ]
      end)

    # A vanished box would otherwise stay on screen until its lifetime ends.
    stale_markers =
      state.previous_indexes
      |> Enum.reject(&(&1 < length(positioned)))
      |> Enum.flat_map(fn index ->
        [
          %Marker{header: header, ns: @namespace, id: box_id(index), action: Marker.delete()},
          %Marker{header: header, ns: @namespace, id: label_id(index), action: Marker.delete()}
        ]
      end)

    VisionCore.Ros2.ZenohClient.publish(
      state.markers_topic,
      MarkerArray,
      %MarkerArray{markers: markers ++ stale_markers}
    )
  end

  defp box_marker(detection, index, header, state) do
    %Marker{
      header: header,
      ns: @namespace,
      id: box_id(index),
      type: Marker.cube(),
      action: Marker.add(),
      pose: pose_for(detection),
      scale: %Vector3{x: detection.width, y: detection.height, z: detection.depth},
      color: colour_for(detection.score),
      lifetime: state.marker_lifetime
    }
  end

  defp label_marker(detection, index, header, state) do
    %Marker{
      header: header,
      ns: @namespace,
      id: label_id(index),
      type: Marker.text_view_facing(),
      action: Marker.add(),
      pose: %Pose{
        position: %Point{
          x: detection.x,
          # Just above the top of the box. -Y is up in an optical
          # frame (x right, y down, z forward), which is why this
          # subtracts.
          y: detection.y - detection.height / 2.0 - 0.05,
          z: detection.z
        },
        orientation: %Quaternion{x: 0.0, y: 0.0, z: 0.0, w: 1.0}
      },
      # For TEXT_VIEW_FACING only scale.z is read: it is the text
      # height in metres.
      scale: %Vector3{x: 0.0, y: 0.0, z: 0.08},
      color: %ColorRGBA{r: 1.0, g: 1.0, b: 1.0, a: 0.9},
      text:
        "#{detection.label} #{:erlang.float_to_binary(detection.score, decimals: 2)} " <>
          "#{:erlang.float_to_binary(detection.z, decimals: 2)}m",
      lifetime: state.marker_lifetime
    }
  end

  # Two markers per detection, so the ids must not collide.
  defp box_id(index), do: index * 2
  defp label_id(index), do: index * 2 + 1

  defp publish_detections(positioned, header, state) do
    detections =
      positioned
      |> Enum.with_index()
      |> Enum.map(fn {detection, index} ->
        %Detection3D{
          header: header,
          results: [
            %ObjectHypothesisWithPose{
              hypothesis: %ObjectHypothesis{
                class_id: detection.label,
                score: detection.score / 1.0
              },
              pose: %PoseWithCovariance{pose: pose_for(detection)}
            }
          ],
          bbox: %BoundingBox3D{
            center: pose_for(detection),
            size: %Vector3{x: detection.width, y: detection.height, z: detection.depth}
          },
          id: Integer.to_string(index)
        }
      end)

    VisionCore.Ros2.ZenohClient.publish(
      state.detections_topic,
      Detection3DArray,
      %Detection3DArray{header: header, detections: detections}
    )
  end

  # LINE_LOOP closes a box in four points where a LINE_LIST needs eight.
  defp publish_overlay(positioned, header, %Pair{} = pair, state) do
    {map_binary, state} = rectification_map_binary(pair, state)

    boxes =
      Enum.map(positioned, fn detection ->
        vertices =
          detection.box
          |> Fusion.perimeter(state.outline_segments)
          |> Enum.map(&to_raw_pixel(&1, map_binary, pair))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(fn {x, y} -> %Point2{x: x, y: y} end)

        %PointsAnnotation{
          timestamp: header.stamp,
          type: PointsAnnotation.line_loop(),
          points: vertices,
          outline_color: overlay_colour(detection.score),
          outline_colors: [],
          fill_color: %Color{a: 0.0},
          thickness: 2.0
        }
      end)

    labels =
      Enum.map(positioned, fn detection ->
        # Anchored just above the box's top-left corner, in raw
        # pixels like everything else in this message.
        {x, y} =
          {detection.box.x0, detection.box.y0}
          |> to_raw_pixel(map_binary, pair)
          |> Kernel.||({detection.box.x0, detection.box.y0})

        %TextAnnotation{
          timestamp: header.stamp,
          position: %Point2{x: x, y: max(y - 4.0, 10.0)},
          text: label_text(detection),
          font_size: state.label_font_size,
          text_color: %Color{r: 1.0, g: 1.0, b: 1.0, a: 1.0},
          # A dark plate behind the text, so a label over a bright
          # part of the image is still readable.
          background_color: %Color{r: 0.0, g: 0.0, b: 0.0, a: 0.6}
        }
      end)

    VisionCore.Ros2.ZenohClient.publish(state.overlay_topic, ImageAnnotations, %ImageAnnotations{
      timestamp: header.stamp,
      circles: [],
      points: boxes,
      texts: labels,
      metadata: []
    })

    state
  end

  defp label_text(detection) do
    "#{detection.label} #{:erlang.float_to_binary(detection.score, decimals: 2)} " <>
      "#{:erlang.float_to_binary(detection.z, decimals: 2)}m"
  end

  # The `colour_for/1` ramp as foxglove_msgs/Color (float64), not std_msgs/ColorRGBA.
  defp overlay_colour(score) do
    %Color{r: 1.0 - score, g: score, b: 0.15, a: 1.0}
  end

  # Without a calibration, rectified and raw pixels are the same.
  defp to_raw_pixel(vertex, nil, _pair), do: vertex

  defp to_raw_pixel(vertex, map_binary, %Pair{} = pair) do
    {width, height} = Pair.size(pair)
    Fusion.remap(map_binary, width, height, vertex)
  end

  defp rectification_map_binary(%Pair{rectification_map_left: nil}, state) do
    {nil, state}
  end

  defp rectification_map_binary(
         %Pair{rectification_map_left: map_mat},
         %{rectification_map_cache: {map_mat, map_binary}} = state
       ) do
    {map_binary, state}
  end

  defp rectification_map_binary(%Pair{rectification_map_left: map_mat}, state) do
    map_binary = Evision.Mat.to_binary(map_mat)
    {map_binary, %{state | rectification_map_cache: {map_mat, map_binary}}}
  end

  defp pose_for(detection) do
    %Pose{
      position: %Point{x: detection.x, y: detection.y, z: detection.z},
      orientation: %Quaternion{x: 0.0, y: 0.0, z: 0.0, w: 1.0}
    }
  end

  # Red at the score floor to green at certainty: confident and marginal detections stand apart.
  defp colour_for(score) do
    %ColorRGBA{r: 1.0 - score, g: score, b: 0.15, a: 0.45}
  end
end
