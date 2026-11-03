defmodule VisionCore.Ros2.Exporter.Detections do
  @moduledoc """
  The ROS 2 messages of the detections of `VisionCore.Detection.Pipeline`,
  which `VisionCore.Ros2.Exporter` publishes: a
  `visualization_msgs/MarkerArray` (what Foxglove's 3D panel renders), a
  `vision_msgs/Detection3DArray` (what nav2 will consume), and a 2D
  overlay on the left raw image.

  ## Frames

  Everything is published in the depth image's own optical frame, the
  frame the pair's left frame carries (`VisionCore.Stereo.Pair.frame_id/1`),
  so it lines up with the point cloud without further transformation.
  The vehicle's transform tree relates that frame to the vehicle body
  — without it a viewer has boxes but nowhere to put them.

  ## Options

    * `:topic_prefix` (`"stereo"`) — markers go to
      `<prefix>/detections/markers`, detections to
      `<prefix>/detections`, and the 2D image overlay to
      `<prefix>/left/detections`.
    * `:marker_lifetime_ms` (`500`) — how long a marker survives
      without being refreshed. Longer than the frame interval so
      markers do not flicker, short enough that a stale box goes away
      promptly.
    * `:label_font_size` (`12.0`) — 2D overlay label size, in pixels.

  ## Drawing on the raw image

  The boxes are computed in *rectified* pixels, but the image the
  vision core publishes — and the one the Foxglove Image panel shows — is
  `image_raw`. The two differ by several pixels on a typical lens, so
  drawing rectified coordinates straight onto the raw image puts the
  box visibly beside the object. The overlay draws each detection's
  `:outline`, which the detection pipeline maps back to the raw image,
  and writes its `:caption` above the outline's first vertex, the box's
  top-left corner.

  The overlay is a `foxglove_msgs/ImageAnnotations` rather than a
  `visualization_msgs/ImageMarker`, because ImageMarker has no text
  type: a box drawn with it can never say what it is.
  """

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
  alias VisionCore.Ros2.Stamp
  alias VisionCore.Stereo.Pair

  @default_topic_prefix "stereo"
  @default_marker_lifetime_ms 500
  @default_label_font_size 12.0

  @namespace "detections"

  @typedoc """
  A message to publish: its topic, its module and the message, and for the
  markers the options `VisionCore.Ros2.ZenohClient.publish/4` takes.
  """
  @type message :: {String.t(), module(), struct()} | {String.t(), module(), struct(), keyword()}

  @typedoc """
  The topics, the frame of a pair that carries none, the marker lifetime
  and the font size, from `new/1`.
  """
  @type t :: %{
          markers_topic: String.t(),
          detections_topic: String.t(),
          overlay_topic: String.t(),
          default_frame_id: String.t(),
          marker_lifetime: struct(),
          label_font_size: float()
        }

  @doc "The topics and settings of the detection `options`; see the module doc."
  @spec new(keyword()) :: t()
  def new(options) do
    topic_prefix = Keyword.get(options, :topic_prefix, @default_topic_prefix)

    %{
      markers_topic: "#{topic_prefix}/detections/markers",
      detections_topic: "#{topic_prefix}/detections",
      overlay_topic: "#{topic_prefix}/left/detections",
      default_frame_id: "#{topic_prefix}_left",
      marker_lifetime:
        options
        |> Keyword.get(:marker_lifetime_ms, @default_marker_lifetime_ms)
        |> Duration.from_milliseconds(),
      label_font_size: Keyword.get(options, :label_font_size, @default_label_font_size)
    }
  end

  @doc """
  The messages of `detections`, found on `pair`: the markers, the
  detections and the overlay. The markers of the detections past the
  last of these, among the `drawn` of the result before, are deleted:
  a vanished box would otherwise stay on screen until its lifetime ends.
  A marker array that deletes is published with `keep: true`, since the
  arrays after it do not delete those markers again.
  """
  @spec messages([map()], Pair.t(), t(), non_neg_integer()) :: [message()]
  def messages(detections, %Pair{} = pair, settings, drawn) do
    header = %Header{
      stamp: Stamp.stamp_from_monotonic(Pair.capture_ns(pair)),
      frame_id: Pair.frame_id(pair) || settings.default_frame_id
    }

    [
      {settings.markers_topic, MarkerArray, markers(detections, header, settings, drawn),
       keep: drawn > length(detections)},
      {settings.detections_topic, Detection3DArray, detection_array(detections, header)},
      {settings.overlay_topic, ImageAnnotations, overlay(detections, header, settings)}
    ]
  end

  defp markers(detections, header, settings, drawn) do
    markers =
      detections
      |> Enum.with_index()
      |> Enum.flat_map(fn {detection, index} ->
        [
          box_marker(detection, index, header, settings),
          label_marker(detection, index, header, settings)
        ]
      end)

    stale_markers =
      Enum.flat_map(length(detections)..(drawn - 1)//1, fn index ->
        [
          %Marker{header: header, ns: @namespace, id: box_id(index), action: Marker.delete()},
          %Marker{header: header, ns: @namespace, id: label_id(index), action: Marker.delete()}
        ]
      end)

    %MarkerArray{markers: markers ++ stale_markers}
  end

  defp box_marker(detection, index, header, settings) do
    %Marker{
      header: header,
      ns: @namespace,
      id: box_id(index),
      type: Marker.cube(),
      action: Marker.add(),
      pose: pose_for(detection),
      scale: %Vector3{x: detection.width, y: detection.height, z: detection.depth},
      color: colour_for(detection.score),
      lifetime: settings.marker_lifetime
    }
  end

  defp label_marker(detection, index, header, settings) do
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
      text: detection.caption,
      lifetime: settings.marker_lifetime
    }
  end

  # Two markers per detection, so the ids must not collide.
  defp box_id(index), do: index * 2
  defp label_id(index), do: index * 2 + 1

  defp detection_array(detections, header) do
    detections =
      detections
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

    %Detection3DArray{header: header, detections: detections}
  end

  # LINE_LOOP closes a box in four points where a LINE_LIST needs eight.
  defp overlay(detections, header, settings) do
    boxes =
      Enum.map(detections, fn detection ->
        %PointsAnnotation{
          timestamp: header.stamp,
          type: PointsAnnotation.line_loop(),
          points: Enum.map(detection.outline, fn {x, y} -> %Point2{x: x, y: y} end),
          outline_color: overlay_colour(detection.score),
          outline_colors: [],
          fill_color: %Color{a: 0.0},
          thickness: 2.0
        }
      end)

    labels =
      Enum.map(detections, fn %{outline: [{x, y} | _rest]} = detection ->
        %TextAnnotation{
          timestamp: header.stamp,
          position: %Point2{x: x, y: max(y - 4.0, 10.0)},
          text: detection.caption,
          font_size: settings.label_font_size,
          text_color: %Color{r: 1.0, g: 1.0, b: 1.0, a: 1.0},
          # A dark plate behind the text, so a label over a bright
          # part of the image is still readable.
          background_color: %Color{r: 0.0, g: 0.0, b: 0.0, a: 0.6}
        }
      end)

    %ImageAnnotations{
      timestamp: header.stamp,
      circles: [],
      points: boxes,
      texts: labels,
      metadata: []
    }
  end

  # The `colour_for/1` ramp as foxglove_msgs/Color (float64), not std_msgs/ColorRGBA.
  defp overlay_colour(score) do
    %Color{r: 1.0 - score, g: score, b: 0.15, a: 1.0}
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
