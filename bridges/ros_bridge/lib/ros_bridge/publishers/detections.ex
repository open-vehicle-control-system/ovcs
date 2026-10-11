defmodule RosBridge.Publishers.Detections do
  @moduledoc """
  Turns 2D detections into 3D ones by fusing them with the stereo
  depth map, and publishes both a `visualization_msgs/MarkerArray`
  (what Foxglove's 3D panel renders) and a
  `vision_msgs/Detection3DArray` (what nav2 will consume).

  Registers as a listener on `RosBridge.StereoCamera.OpenCV`, so it
  sees the same `Result` the stereo publisher does — including the
  rectified left image and the metric depth `Mat`. That is the whole
  reason detection is nearly free here: the pixels are already
  decoded and rectified, the depth is already computed, and the
  accelerator is otherwise idle.

  ## How a box becomes a position

  The box is in rectified left-camera pixels and the depth map is in
  the same frame, pixel for pixel, so the fusion is a lookup:

    * take the **median** of the finite depths inside the middle
      portion of the box (`:depth_sample_fraction`). Median because a
      box around a person contains background at its corners, and a
      mean would drag the distance towards the wall behind them;
      the middle portion for the same reason.
    * unproject the box centre with the rectified intrinsics:
      `X = (u - cx) * Z / fx`, `Y = (v - cy) * Z / fy`.
    * size the box in metres the same way, from its pixel width and
      height at that distance.

  A detection with no valid depth inside it is **dropped**, not
  published at a guessed distance. Stereo returns nothing on
  untextured surfaces, and a box floating at a made-up range is worse
  than an absent one.

  ## Frames

  Everything is published in the depth image's own optical frame, so
  it lines up with the point cloud without further transformation.
  `RosBridge.Publishers.StaticTransform` is what relates that frame
  to the vehicle body — without it a viewer has boxes but nowhere to
  put them.

  ## Options

    * `:topic_prefix` (`"stereo"`) — markers go to
      `<prefix>/detections/markers`, detections to
      `<prefix>/detections`, and the 2D image overlay to
      `<prefix>/left/detections`.
    * `:frame_id` (`"<prefix>_left"`) — must match the frame the
      stereo unit stamps its depth image with, since the boxes are
      positioned in that image's pixels.
    * `:labels` (COCO 80) — class id to name.
    * `:min_score` (`0.4`) — the Port filters at its own threshold
      too; this is the publish-side floor.
    * `:max_detections` (`20`).
    * `:depth_sample_fraction` (`0.5`) — central fraction of the box
      used for the depth median.
    * `:marker_lifetime_ms` (`500`) — how long a marker survives
      without being refreshed. Longer than the frame interval so
      markers do not flicker, short enough that a stale box goes away
      promptly.
    * `:inference` (`RosBridge.Inference.Hailo`) — the detection
      backend module, which is also its registered name. See
      `RosBridge.Inference` for the contract and the alternatives.
    * `:detect_every_n` (`1`) — run inference on every nth stereo
      result.
    * `:outline_segments` (`4`) — how finely each box edge is
      subdivided for the 2D overlay. See "Drawing on the raw image".
    * `:label_font_size` (`12.0`) — 2D overlay label size, in pixels.

  ## Drawing on the raw image

  The boxes are computed in *rectified* pixels, but the image the
  bridge publishes — and the one the Foxglove Image panel shows — is
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

  ## One inference in flight

  Only one submitted `Result` is held, and a reply is matched on the
  current sequence number. That relies on the backend answering
  `{:error, :busy}` while an inference is in flight, so the sequence
  only advances on an accepted frame; a backend that accepted
  overlapping requests would have its earlier replies discarded as
  stale.
  """
  use GenServer

  require Logger

  alias Ros2.BuiltinInterfaces.Msg.Duration
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, PoseWithCovariance, Quaternion, Vector3}
  alias Ros2.StdMsgs.Msg.{ColorRGBA, Header}
  alias Ros2.VisionMsgs.Msg.{BoundingBox3D, Detection3D, Detection3DArray}
  alias Ros2.VisionMsgs.Msg.{ObjectHypothesis, ObjectHypothesisWithPose}
  alias Ros2.FoxgloveMsgs.Msg.{Color, ImageAnnotations, Point2, PointsAnnotation, TextAnnotation}
  alias Ros2.VisualizationMsgs.Msg.{Marker, MarkerArray}
  alias RosBridge.Perception.Fusion
  alias RosBridge.StereoCamera.Result
  alias RosBridge.Timing

  @coco_labels ~w(person bicycle car motorcycle airplane bus train truck boat
                  traffic_light fire_hydrant stop_sign parking_meter bench bird cat
                  dog horse sheep cow elephant bear zebra giraffe backpack umbrella
                  handbag tie suitcase frisbee skis snowboard sports_ball kite
                  baseball_bat baseball_glove skateboard surfboard tennis_racket
                  bottle wine_glass cup fork knife spoon bowl banana apple sandwich
                  orange broccoli carrot hot_dog pizza donut cake chair couch
                  potted_plant bed dining_table toilet tv laptop mouse remote
                  keyboard cell_phone microwave oven toaster sink refrigerator book
                  clock vase scissors teddy_bear hair_drier toothbrush)

  @default_topic_prefix "stereo"
  @default_min_score 0.4
  @default_max_detections 20
  @default_depth_sample_fraction 0.5
  @default_marker_lifetime_ms 500
  @default_detect_every_n 1
  @default_outline_segments 4
  @default_label_font_size 12.0

  @namespace "detections"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The COCO class names, indexed by class id."
  def labels, do: @coco_labels

  @impl GenServer
  def init(opts) do
    topic_prefix = Keyword.get(opts, :topic_prefix, @default_topic_prefix)

    state = %{
      markers_topic: "#{topic_prefix}/detections/markers",
      detections_topic: "#{topic_prefix}/detections",
      overlay_topic: "#{topic_prefix}/left/detections",
      frame_id: Keyword.get(opts, :frame_id, "#{topic_prefix}_left"),
      labels: Keyword.get(opts, :labels, @coco_labels),
      min_score: Keyword.get(opts, :min_score, @default_min_score),
      max_detections: Keyword.get(opts, :max_detections, @default_max_detections),
      depth_sample_fraction:
        Keyword.get(opts, :depth_sample_fraction, @default_depth_sample_fraction),
      marker_lifetime:
        opts
        |> Keyword.get(:marker_lifetime_ms, @default_marker_lifetime_ms)
        |> Duration.from_milliseconds(),
      detect_every_n: Keyword.get(opts, :detect_every_n, @default_detect_every_n),
      # Doubles as the server name: every backend registers under its own module.
      inference: Keyword.get(opts, :inference, RosBridge.Inference.Hailo),
      outline_segments: Keyword.get(opts, :outline_segments, @default_outline_segments),
      label_font_size: Keyword.get(opts, :label_font_size, @default_label_font_size),
      # Keyed on the Mat itself, so a calibration reload invalidates it.
      rectification_map_cache: nil,
      sequence: 0,
      frame_count: 0,
      # The Result submitted with the in-flight inference: its boxes belong to that depth map.
      pending: nil,
      published_count: 0,
      # Detection indexes drawn last frame; those not redrawn get an explicit DELETE.
      previous_indexes: MapSet.new()
    }

    RosBridge.StereoCamera.OpenCV.register_listener(RosBridge.StereoCamera.OpenCV, self())

    Logger.info(
      "#{__MODULE__} publishing markers on #{state.markers_topic} and " <>
        "detections on #{state.detections_topic} (frame #{state.frame_id})"
    )

    {:ok, state}
  end

  @impl GenServer
  def handle_cast({:stereo_result, %Result{} = result}, state) do
    frame_count = state.frame_count + 1
    state = %{state | frame_count: frame_count}

    cond do
      rem(frame_count, state.detect_every_n) != 0 ->
        {:noreply, state}

      is_nil(result.left_rectified) or is_nil(result.depth_m) ->
        {:noreply, state}

      true ->
        {:noreply, submit(result, state)}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  # Overwrites `pending`; see "One inference in flight" in the moduledoc.
  defp submit(result, state) do
    sequence = state.sequence + 1

    case state.inference.detect(state.inference, sequence, result.left_rectified) do
      :ok -> %{state | sequence: sequence, pending: result}
      # Busy or unavailable: skip this frame silently. The backend logs
      # the unavailable case once at startup; a per-frame log here
      # would be the loudest thing in the RingLogger.
      {:error, _reason} -> state
    end
  end

  @impl GenServer
  def handle_info(
        {:inference_detections, sequence, detections},
        %{sequence: sequence, pending: pending} = state
      )
      when not is_nil(pending) do
    {:noreply, publish(detections, pending, %{state | pending: nil})}
  end

  # A reply for a frame no longer waited on.
  def handle_info({:inference_detections, _stale, _detections}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp publish(detections, %Result{} = result, state) do
    stamp = Timing.time_message_for(result.capture_ns)
    header = %Header{stamp: stamp, frame_id: state.frame_id}

    positioned =
      detections
      |> Enum.filter(&(&1.score >= state.min_score))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(state.max_detections)
      |> Enum.map(&position(&1, result, state))
      |> Enum.reject(&is_nil/1)

    publish_markers(positioned, header, state)
    publish_detections(positioned, header, state)
    state = publish_overlay(positioned, header, result, state)

    %{
      state
      | published_count: state.published_count + length(positioned),
        previous_indexes: MapSet.new(Enum.with_index(positioned), fn {_, index} -> index end)
    }
  end

  defp position(detection, %Result{} = result, state) do
    case Fusion.median_depth(result.depth_m, detection, state.depth_sample_fraction) do
      nil ->
        nil

      depth_m ->
        geometry =
          Fusion.unproject(detection, depth_m, principal_point(result), result.focal_length)

        geometry
        |> Map.merge(%{
          # The 2D box in rectified pixels, kept for the image overlay.
          box: detection,
          class_id: detection.class_id,
          label: label_for(detection.class_id, state.labels),
          score: detection.score,
          # One view cannot measure extent along the optical axis; a
          # thin slab marks where the surface is, not how deep it goes.
          depth: 0.1
        })
    end
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

    RosBridge.ZenohClient.publish(
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

    RosBridge.ZenohClient.publish(
      state.detections_topic,
      Detection3DArray,
      %Detection3DArray{header: header, detections: detections}
    )
  end

  # LINE_LOOP closes a box in four points where a LINE_LIST needs eight.
  defp publish_overlay(positioned, header, %Result{} = result, state) do
    {map_binary, state} = rectification_map_binary(result, state)

    boxes =
      Enum.map(positioned, fn detection ->
        vertices =
          detection.box
          |> Fusion.perimeter(state.outline_segments)
          |> Enum.map(&to_raw_pixel(&1, map_binary, result))
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
          |> to_raw_pixel(map_binary, result)
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

    RosBridge.ZenohClient.publish(state.overlay_topic, ImageAnnotations, %ImageAnnotations{
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
  defp to_raw_pixel(vertex, nil, _result), do: vertex

  defp to_raw_pixel(vertex, map_binary, %Result{} = result) do
    Fusion.remap(map_binary, result.width, result.height, vertex)
  end

  defp rectification_map_binary(%Result{rectification_map_left: nil}, state) do
    {nil, state}
  end

  defp rectification_map_binary(
         %Result{rectification_map_left: map_mat},
         %{rectification_map_cache: {map_mat, map_binary}} = state
       ) do
    {map_binary, state}
  end

  defp rectification_map_binary(%Result{rectification_map_left: map_mat}, state) do
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

  defp label_for(class_id, labels), do: Enum.at(labels, class_id, "class_#{class_id}")

  # The image centre is only a fallback for a Result without calibration; do not rely on it.
  defp principal_point(%Result{principal_point: {cx, cy}}), do: {cx, cy}

  defp principal_point(%Result{} = result) do
    {result.width / 2.0, result.height / 2.0}
  end
end
