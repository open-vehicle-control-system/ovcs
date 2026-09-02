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

  ## Opts

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
    * `:detect_every_n` (`1`) — run inference on every nth stereo
      result.
    * `:outline_segments` (`4`) — how finely each box edge is
      subdivided for the 2D overlay. See "Drawing on the raw image".

  ## Drawing on the raw image

  The boxes are computed in *rectified* pixels, but the image the
  bridge publishes — and the one the Foxglove Image panel shows — is
  `image_raw`. On the Mini those differ by 10 pixels on average and
  up to 23 on a 480-wide frame, so drawing rectified coordinates
  straight onto the raw image puts the box visibly beside the object.

  Rather than publish a second, rectified image stream, each outline
  vertex is mapped back through OpenCV's rectification map. A
  straight edge in rectified space is a curve in raw space, so edges
  are subdivided (`:outline_segments`) and each vertex mapped
  individually.
  """
  use GenServer

  require Logger

  alias Ros2.BuiltinInterfaces.Msg.Duration
  alias Ros2.GeometryMsgs.Msg.{Point, Pose, PoseWithCovariance, Quaternion, Vector3}
  alias Ros2.StdMsgs.Msg.{ColorRGBA, Header}
  alias Ros2.VisionMsgs.Msg.{BoundingBox3D, Detection3D, Detection3DArray}
  alias Ros2.VisionMsgs.Msg.{ObjectHypothesis, ObjectHypothesisWithPose}
  alias Ros2.VisualizationMsgs.Msg.{ImageMarker, Marker, MarkerArray}
  alias RosBridge.Inference.Hailo
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

  @namespace "detections"

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def labels, do: @coco_labels

  @impl true
  def init(opts) do
    prefix = Keyword.get(opts, :topic_prefix, @default_topic_prefix)

    state = %{
      markers_topic: "#{prefix}/detections/markers",
      detections_topic: "#{prefix}/detections",
      overlay_topic: "#{prefix}/left/detections",
      frame_id: Keyword.get(opts, :frame_id, "#{prefix}_left"),
      labels: Keyword.get(opts, :labels, @coco_labels),
      min_score: Keyword.get(opts, :min_score, @default_min_score),
      max_detections: Keyword.get(opts, :max_detections, @default_max_detections),
      sample_fraction:
        Keyword.get(opts, :depth_sample_fraction, @default_depth_sample_fraction),
      lifetime:
        opts
        |> Keyword.get(:marker_lifetime_ms, @default_marker_lifetime_ms)
        |> Duration.from_milliseconds(),
      detect_every_n: Keyword.get(opts, :detect_every_n, @default_detect_every_n),
      outline_segments: Keyword.get(opts, :outline_segments, @default_outline_segments),
      # The rectification map is constant, but reading a 500 KB Mat
      # to a binary every frame is not free — cache it, keyed on the
      # Mat itself so a calibration reload invalidates it.
      rectification_map: nil,
      seq: 0,
      frame_count: 0,
      # The Result whose frame is currently at the accelerator. Held
      # because the boxes come back asynchronously and the depth map
      # they belong to is the one submitted with them, not whatever
      # the pipeline has produced since.
      pending: nil,
      published: 0,
      # Marker ids we drew last time. Anything not redrawn this frame
      # gets an explicit DELETE, so a box does not linger until its
      # lifetime expires.
      previous_ids: MapSet.new()
    }

    RosBridge.StereoCamera.OpenCV.register_listener(RosBridge.StereoCamera.OpenCV, self())

    Logger.info(
      "#{__MODULE__} publishing markers on #{state.markers_topic} and " <>
        "detections on #{state.detections_topic} (frame #{state.frame_id})"
    )

    {:ok, state}
  end

  @impl true
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

  # Overwrites `pending` without checking it, and the reply clause
  # matches on the current `seq` — so if a stereo result were ever
  # processed while an inference was still outstanding, `seq` would
  # advance and the earlier reply would be discarded as stale.
  #
  # `Hailo.detect/3` is what closes that today: it answers
  # `{:error, :busy}` while an inference is in flight, so `seq` only
  # advances on a frame that was actually accepted. Measured on the
  # device that window never opens — `dropped: 0` across thousands of
  # frames, because inference and publish finish well inside the
  # ~77 ms frame period. It would open if the frame rate rose
  # materially, and the fix then is a `seq -> Result` map with a
  # staleness sweep rather than a single slot.
  defp submit(result, state) do
    seq = state.seq + 1

    case Hailo.detect(seq, result.left_rectified) do
      :ok -> %{state | seq: seq, pending: result}
      # Busy or unavailable: skip this frame silently. `Hailo` logs
      # the unavailable case once at startup; a per-frame log here
      # would be the loudest thing in the RingLogger.
      {:error, _reason} -> state
    end
  end

  @impl true
  def handle_info({:hailo_detections, seq, detections}, %{seq: seq, pending: pending} = state)
      when not is_nil(pending) do
    {:noreply, publish(detections, pending, %{state | pending: nil})}
  end

  # A reply for a frame we have stopped waiting on.
  def handle_info({:hailo_detections, _stale, _detections}, state), do: {:noreply, state}

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
      | published: state.published + length(positioned),
        previous_ids: MapSet.new(Enum.with_index(positioned), fn {_d, i} -> i end)
    }
  end

  # ── 2D box + depth map -> a position and size in metres ──────────

  defp position(detection, %Result{} = result, state) do
    case Fusion.median_depth(result.depth_m, detection, state.sample_fraction) do
      nil ->
        nil

      z ->
        geometry =
          Fusion.unproject(detection, z, principal_point(result), result.focal_length)

        geometry
        |> Map.merge(%{
          # The 2D box in rectified pixels, kept for the image overlay.
          box: detection,
          class_id: detection.class_id,
          label: label_for(detection.class_id, state.labels),
          score: detection.score,
          # Nothing measures an object's extent along the optical
          # axis from one view. A thin slab is the honest shape: it
          # says "this is where the surface is", not "this is how
          # deep the object goes".
          depth: 0.1
        })
    end
  end

  # ── message building ─────────────────────────────────────────────

  defp publish_markers(positioned, header, state) do
    boxes =
      positioned
      |> Enum.with_index()
      |> Enum.flat_map(fn {detection, index} ->
        [box_marker(detection, index, header, state), label_marker(detection, index, header, state)]
      end)

    # Explicitly delete any id we drew last time and did not redraw.
    # Without this a box that disappears stays on screen until its
    # lifetime runs out, which reads as a detection that is still
    # there.
    stale =
      state.previous_ids
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
      %MarkerArray{markers: boxes ++ stale}
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
      lifetime: state.lifetime
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
      text: "#{detection.label} #{:erlang.float_to_binary(detection.score, decimals: 2)} " <>
              "#{:erlang.float_to_binary(detection.z, decimals: 2)}m",
      lifetime: state.lifetime
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

  # ── 2D overlay on the raw left image ─────────────────────────────

  # One ImageMarker, not one per box: ROS 2 has no ImageMarkerArray
  # and the Image panel takes a single message per annotation topic,
  # so every box goes into one LINE_LIST whose points are read in
  # pairs.
  defp publish_overlay(positioned, header, %Result{} = result, state) do
    {map_binary, state} = rectification_map(result, state)

    points =
      positioned
      |> Enum.flat_map(fn detection ->
        detection.box
        |> Fusion.outline(state.outline_segments)
        |> Enum.map(&to_raw_pixel(&1, map_binary, result))
      end)
      |> Enum.reject(&is_nil/1)
      # A dropped vertex would pair the wrong points together and draw
      # a segment across the image, so an odd count loses its tail.
      |> drop_odd_tail()

    colours = outline_colours(positioned, points, state)

    RosBridge.ZenohClient.publish(state.overlay_topic, ImageMarker, %ImageMarker{
      header: header,
      ns: @namespace,
      id: 0,
      type: ImageMarker.line_list(),
      action: ImageMarker.add(),
      scale: 1.0,
      outline_color: %ColorRGBA{r: 0.2, g: 0.9, b: 0.2, a: 1.0},
      filled: 0,
      fill_color: %ColorRGBA{a: 0.0},
      lifetime: state.lifetime,
      points: Enum.map(points, fn {x, y} -> %Point{x: x, y: y, z: 0.0} end),
      outline_colors: colours
    })

    state
  end

  # Without a calibration there is no map and no rectification, so the
  # rectified and raw pixels are the same thing.
  defp to_raw_pixel(vertex, nil, _result), do: vertex

  defp to_raw_pixel(vertex, map_binary, %Result{} = result) do
    Fusion.remap(map_binary, result.width, result.height, vertex)
  end

  defp drop_odd_tail(points) when rem(length(points), 2) == 0, do: points
  defp drop_odd_tail(points), do: Enum.drop(points, -1)

  # One colour per point, so each box keeps its own score colour in
  # the shared marker. Every vertex of a box gets the same colour, and
  # a box contributes 8 x outline_segments of them.
  defp outline_colours(positioned, points, state) do
    per_box = 8 * state.outline_segments

    positioned
    |> Enum.flat_map(fn detection ->
      List.duplicate(%{colour_for(detection.score) | a: 1.0}, per_box)
    end)
    |> Enum.take(length(points))
  end

  defp rectification_map(%Result{rectification_map_left: nil}, state) do
    {nil, state}
  end

  defp rectification_map(%Result{rectification_map_left: map}, %{rectification_map: {map, binary}} = state) do
    {binary, state}
  end

  defp rectification_map(%Result{rectification_map_left: map}, state) do
    binary = Evision.Mat.to_binary(map)
    {binary, %{state | rectification_map: {map, binary}}}
  end

  defp pose_for(detection) do
    %Pose{
      position: %Point{x: detection.x, y: detection.y, z: detection.z},
      orientation: %Quaternion{x: 0.0, y: 0.0, z: 0.0, w: 1.0}
    }
  end

  # Red at the score floor through green at certainty, so a glance at
  # the 3D panel separates a confident detection from a marginal one.
  defp colour_for(score) do
    %ColorRGBA{r: 1.0 - score, g: score, b: 0.15, a: 0.45}
  end

  defp label_for(class_id, labels), do: Enum.at(labels, class_id, "class_#{class_id}")

  # The rectified principal point, carried on the Result from the
  # backend's calibration. The image centre is the fallback for a
  # Result built without one — close enough to look plausible, which
  # is exactly why it is worth not relying on.
  defp principal_point(%Result{principal_point: {cx, cy}}), do: {cx, cy}

  defp principal_point(%Result{} = result) do
    {result.width / 2.0, result.height / 2.0}
  end

end
