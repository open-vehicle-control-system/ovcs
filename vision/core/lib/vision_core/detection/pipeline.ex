defmodule VisionCore.Detection.Pipeline do
  @moduledoc """
  Detects objects on the stereo unit's pairs, or on a camera of its own,
  and places them in 3D: hands the rectified left image of every
  `:detect_every_n`-th `VisionCore.Stereo.Pair` to a
  `VisionCore.Detection.Backend`, fuses the boxes it returns with that
  pair's depth map, and publishes the result through
  `VisionCore.Outputs` under `{:detections, server}`, `server` being the
  name it is registered under (`VisionCore.Detection.server/2`). The
  default pipeline, `:detection`, publishes `{:detections, pair,
  detections}` under `{:detections, VisionCore.Detection.Pipeline}`; a
  named one `{:detections, pair, detections, name}`.

  With `source: {:camera, name}` it detects on the frames of the camera
  of its own `name` instead (see "A camera source" below), and publishes
  `{:detections, frame, detections, name}`, `frame` the
  `VisionCore.Camera.Frame` the boxes were found on.

  Subscribes to the pairs of `VisionCore.Stereo.Pipeline`, so it sees
  the pairs every other consumer does, rectified left image and metric
  depth included. That is why detection is nearly free here: the pixels
  are already decoded and rectified, the depth is already computed, and
  the accelerator is otherwise idle.

  ## How a box becomes a position

  The box is in rectified left-camera pixels and the depth map is in
  the same frame, pixel for pixel, so the fusion is a lookup
  (`VisionCore.Detection.Fusion`):

    * take the **median** of the finite depths inside the middle
      portion of the box (`:depth_sample_fraction`). Median because a
      box around a person contains background at its corners, and a
      mean would drag the distance towards the wall behind them;
      the middle portion for the same reason.
    * unproject the box centre with the rectified intrinsics:
      `X = (u - cx) * Z / fx`, `Y = (v - cy) * Z / fy`.
    * size the box in metres the same way, from its pixel width and
      height at that distance.

  A detection with no valid depth inside it is **dropped**, not given a
  guessed distance. Stereo returns nothing on untextured surfaces, and
  a box floating at a made-up range is worse than an absent one.

  Each detection is a map with the box's position and size in metres in
  the left optical frame (`:x`, `:y`, `:z`, `:width`, `:height`,
  `:depth`), its 2D `:box` in rectified pixels, `:class_id`, `:label`
  and `:score`, and what every consumer draws of it, computed once here:

    * `:outline` — the box's outline on the left camera frame as it is
      captured, which the dashboard and the ROS 2 overlay draw on. The
      box is in rectified pixels, so each vertex is mapped back through
      the left calibration (`VisionCore.Detection.Fusion.outlines/3`): a
      straight edge in rectified pixels is a curve on the captured
      image, so each edge is cut into `:outline_segments` pieces that
      follow the lens distortion. Its first vertex is the box's top-left
      corner.
    * `:caption` — its label, score and distance, as a viewer writes them
      next to the box: `"person 0.62 1.80m"`.

  ## A camera source

  Hands every `:detect_every_n`-th frame of the camera, as a tensor
  (`VisionCore.Camera.Frame.to_tensor/1`: RGB for an RGB frame, its luma
  for a JPEG one), to the backend, which shrinks it whole to its model's
  input. A frame that comes while the boxes of the one before wait for
  their pair is skipped, so the detection rate is bounded by the stereo
  pipeline's latency as well as the inference's. Its boxes are placed with the depth of
  the stereo pair captured closest to the frame, projected into the
  camera's image through its calibration and pose
  (`VisionCore.Detection.CameraSource`), only for a frame with boxes. A
  box with no distance is kept: its position and size are `nil`, and
  its `:bearing` says where it is seen. Each detection is in the camera's
  optical frame, its `:box` and `:outline`, its four corners, in the
  frame's pixels, and has a `:bearing`, `{azimuth, elevation}` in
  radians, `nil` without a calibration. Its caption has its distance
  only when it has one: `"person 0.62"`.

  Only a named pipeline takes a camera source: the default pipeline is
  the stereo pair's.

  ## One inference in flight

  Only one submitted pair is held, and a reply is matched on the
  current sequence number. That relies on the backend answering
  `{:error, :busy}` while an inference is in flight, so the sequence
  only advances on an accepted frame; a backend that accepted
  overlapping requests would have its earlier replies discarded as
  stale.

  ## Options

    * `:name` (`:detection`) — the pipeline's name: it registers as
      `VisionCore.Detection.server(VisionCore.Detection.Pipeline, name)`
      and declares its parameter groups as `<name>.*`.
    * `:backend` (`VisionCore.Detection.Backend.Hailo`) — the detection
      backend module.
    * `:backend_server` (the `:backend` module) — the name the backend is
      registered under.
    * `:source` (`:stereo`) — the stereo pairs, or `{:camera, name}`,
      the camera of its own `name` (`VisionCore.Camera.Unit`).
    * `:detect_every_n` (`1`) — run inference on every nth pair, or
      frame of a camera source.
    * `:labels` (COCO 80) — class id to name.
    * `:min_score` (`0.4`) — the backend filters at its own threshold
      too; this is the floor for what is passed on.
    * `:max_detections` (`20`).
    * `:depth_sample_fraction` (`0.5`) — central fraction of the box
      used for the depth median.
    * `:outline_segments` (`4`) — pieces each edge of an outline is cut
      into, on the stereo source.
    * `:reprojection_stride` (`3`) — on a camera source, every nth pixel
      and row of the depth map projected into the camera's image.
    * `:pair_wait_ms` (`500`) — on a camera source, the longest a frame's
      boxes wait for the pair captured closest to it.
    * `:config` (the active `VisionCore.Config`) — the configuration the
      camera of a camera source is read from.
  """
  use GenServer

  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Detection
  alias VisionCore.Detection.{CameraSource, Fusion}
  alias VisionCore.Outputs
  alias VisionCore.Stereo.Pair

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

  @default_min_score 0.4
  @default_max_detections 20
  @default_depth_sample_fraction 0.5
  @default_detect_every_n 1
  @default_outline_segments 4
  @default_reprojection_stride 3
  @default_pair_wait_ms 500

  @on_the_beam %{runs_on: :cpu, implementation: :elixir, backend: nil}
  @input_explanation "Takes the rectified left image of the stereo pairs, which the depth " <>
                       "lines up with pixel for pixel, and hands it to the detector. " <>
                       "detect_every_n, fixed in the build, runs detection on one pair out of " <>
                       "n: a higher value leaves the accelerator and the processor more time, " <>
                       "and updates the boxes less often. A pair that arrives while the " <>
                       "detector is still busy is skipped."
  @filtering_explanation "Keeps the detections worth passing on: those scoring at least " <>
                           "min_score, at most max_detections per image, best first. Raise " <>
                           "min_score to drop doubtful boxes, at the risk of missing real " <>
                           "objects; lower it to see more of them, down to the inference " <>
                           "step's own threshold. Both are fixed in the build."
  @placement_explanation "Places each box in 3D with the depth, which lines up with the image " <>
                           "pixel for pixel. It takes the median depth in the middle of the " <>
                           "box, so the background showing at its corners does not pull the " <>
                           "distance away, then turns the box's centre and size into metres " <>
                           "in the left camera's frame. depth_sample_fraction, fixed in the " <>
                           "build, is the share of the box's width and height it samples. A " <>
                           "box with no depth in its middle is dropped rather than given a " <>
                           "guessed distance. Watch the outlines and distances on the left " <>
                           "video."
  @camera_placement_explanation "Places each box in 3D with the depth of the stereo pair " <>
                                  "captured closest to the image, projected into the " <>
                                  "camera's image through its calibration and its pose " <>
                                  "relative to the stereo pair. It takes the median depth " <>
                                  "projected in the middle of the box, then turns the box's " <>
                                  "centre and size into metres in the camera's frame. Fixed " <>
                                  "in the build: depth_sample_fraction, the share of the " <>
                                  "box's width and height it samples; reprojection_stride, " <>
                                  "every how many pixels and rows of the depth it projects, " <>
                                  "a higher value placing faster and less finely; and " <>
                                  "pair_wait_ms, how long the boxes wait for that pair. A " <>
                                  "box with no depth in its middle, or out of the stereo " <>
                                  "pair's view, is kept without a distance, with its " <>
                                  "bearing. Watch the outlines and distances on the camera's " <>
                                  "video."

  def start_link(opts) do
    name = Detection.pipeline_name(opts)
    GenServer.start_link(__MODULE__, opts, name: Detection.server(__MODULE__, name))
  end

  @doc "The COCO class names, indexed by class id."
  def labels, do: @coco_labels

  @impl GenServer
  def init(opts) do
    backend = Keyword.get(opts, :backend, VisionCore.Detection.Backend.Hailo)
    name = Detection.pipeline_name(opts)
    source = Keyword.get(opts, :source, :stereo)

    state = %{
      name: name,
      source: source,
      camera: camera_source(source, name, opts),
      backend: backend,
      backend_server: Keyword.get(opts, :backend_server, backend),
      detect_every_n: Keyword.get(opts, :detect_every_n, @default_detect_every_n),
      labels: Keyword.get(opts, :labels, @coco_labels),
      min_score: Keyword.get(opts, :min_score, @default_min_score),
      max_detections: Keyword.get(opts, :max_detections, @default_max_detections),
      depth_sample_fraction:
        Keyword.get(opts, :depth_sample_fraction, @default_depth_sample_fraction),
      outline_segments: Keyword.get(opts, :outline_segments, @default_outline_segments),
      reprojection_stride: Keyword.get(opts, :reprojection_stride, @default_reprojection_stride),
      pair_wait_ms: Keyword.get(opts, :pair_wait_ms, @default_pair_wait_ms),
      sequence: 0,
      pair_count: 0,
      # The pair, or camera frame, submitted with the in-flight inference: its boxes belong to it.
      pending: nil,
      # A camera frame's boxes waiting for the pair captured closest to it.
      awaiting: nil,
      unmatched_logged: false
    }

    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare(groups(state))

    :ok = Outputs.subscribe({:stereo_pair, VisionCore.Stereo.Pipeline})
    if state.camera, do: :ok = Outputs.subscribe({:camera_frame, state.camera.server})
    {:ok, state}
  end

  defp camera_source(:stereo, _name, _opts), do: nil

  defp camera_source({:camera, _camera}, :detection, _opts),
    do:
      raise(
        ArgumentError,
        "a detection pipeline on a camera needs a :name: the default pipeline, :detection, " <>
          "is the stereo pair's"
      )

  defp camera_source({:camera, camera}, name, opts) when is_atom(camera) do
    config =
      Keyword.get_lazy(opts, :config, &VisionCore.Application.active_config/0) ||
        %VisionCore.Config{}

    CameraSource.new(camera, config, name)
  end

  defp camera_source(source, _name, _opts),
    do:
      raise(
        ArgumentError,
        "its :source is :stereo or {:camera, name}, a camera of its own, got #{inspect(source)}"
      )

  @doc """
  The detection pipeline's steps around the inference, for a running
  `state`: their parameter groups, `<name>.input`, `<name>.filtering` and
  `<name>.placement` in the pipeline `name`, with their settings fixed at
  start. The backend declares the inference step itself
  (`inference_group/2`).
  """
  @spec groups(map()) :: [VisionCore.Parameters.group_declaration()]
  def groups(state) do
    source = Map.get(state, :source, :stereo)

    [
      step(state.name, "input", "Input", 101, %{
        summary: input_summary(source),
        explanation: input_explanation(source),
        compute: @on_the_beam,
        parameters: [
          build_parameter(state, :detect_every_n, "Pairs per detection; 1 detects on every pair")
        ]
      }),
      step(state.name, "filtering", "Filtering", 103, %{
        summary: "Keeps the most confident detections.",
        explanation: @filtering_explanation,
        compute: @on_the_beam,
        parameters: [
          build_parameter(state, :min_score, "Lowest score of a detection passed on"),
          build_parameter(state, :max_detections, "Most detections passed on per image")
        ]
      }),
      step(state.name, "placement", "Placement", 104, %{
        summary: "Places each box in 3D with the median depth in its middle.",
        explanation: placement_explanation(source),
        compute: @on_the_beam,
        parameters: placement_parameters(source, state)
      })
    ]
  end

  defp input_summary(:stereo),
    do: "Hands the rectified left image of every nth stereo pair to the detector."

  defp input_summary({:camera, camera}),
    do: "Hands every nth image of the camera #{camera} to the detector."

  defp input_explanation(:stereo), do: @input_explanation

  defp input_explanation({:camera, camera}),
    do:
      "Takes the images of the camera #{camera} and hands them to the detector, which " <>
        "shrinks each whole to its model's input. detect_every_n, fixed in the build, runs " <>
        "detection on one image out of n: a higher value leaves the accelerator and the " <>
        "processor more time, and updates the boxes less often. An image that arrives while " <>
        "the detector is still busy is skipped."

  defp placement_explanation(:stereo), do: @placement_explanation
  defp placement_explanation({:camera, _camera}), do: @camera_placement_explanation

  defp placement_parameters(source, state) do
    [
      build_parameter(
        state,
        :depth_sample_fraction,
        "Share of the box's width and height whose depths are sampled"
      )
    ] ++
      case source do
        :stereo ->
          []

        {:camera, _camera} ->
          [
            build_parameter(
              state,
              :reprojection_stride,
              "Every how many pixels and rows of the depth are projected"
            ),
            build_parameter(state, :pair_wait_ms, "Longest wait for the matching pair, in ms")
          ]
      end
  end

  @doc """
  The inference step of the detection pipeline `pipeline`,
  `<pipeline>.inference`, between its input and its filtering. The
  backend running the model declares it, `fields` giving its summary,
  explanation, compute and parameters.
  """
  @spec inference_group(atom(), map()) :: VisionCore.Parameters.group_declaration()
  def inference_group(pipeline, fields), do: step(pipeline, "inference", "Inference", 102, fields)

  defp step(pipeline, id, name, position, fields) do
    Map.merge(
      %{
        id: "#{pipeline}.#{id}",
        name: name,
        kind: :stage,
        pipeline: pipeline,
        position: position
      },
      fields
    )
  end

  defp build_parameter(state, key, description),
    do: VisionCore.Stereo.Parameters.build_parameter({key, Map.fetch!(state, key)}, description)

  @impl GenServer
  def handle_cast({:stereo_pair, %Pair{} = pair}, %{camera: %CameraSource{} = camera} = state) do
    state = %{state | camera: CameraSource.add_pair(camera, pair)}

    case state.awaiting do
      nil -> {:noreply, state}
      awaiting -> {:noreply, place_awaiting(awaiting, state, final: false)}
    end
  end

  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    pair_count = state.pair_count + 1
    state = %{state | pair_count: pair_count}

    cond do
      rem(pair_count, state.detect_every_n) != 0 -> {:noreply, state}
      is_nil(pair.left) or is_nil(pair.depth) -> {:noreply, state}
      true -> {:noreply, submit(pair, state)}
    end
  end

  # A frame that comes while boxes wait for their pair is skipped, as one that comes during an inference.
  def handle_cast({:camera_frame, %Frame{}}, %{camera: %CameraSource{}, awaiting: %{}} = state),
    do: {:noreply, state}

  def handle_cast({:camera_frame, %Frame{} = frame}, %{camera: %CameraSource{}} = state) do
    pair_count = state.pair_count + 1
    state = %{state | pair_count: pair_count}

    with 0 <- rem(pair_count, state.detect_every_n),
         {:ok, image} <- Frame.to_tensor(frame) do
      {:noreply, submit(frame, image, state)}
    else
      _skipped -> {:noreply, state}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  defp submit(pair, state), do: submit(pair, pair.left, state)

  # Overwrites `pending`; see "One inference in flight" in the moduledoc.
  defp submit(source, image, state) do
    sequence = state.sequence + 1

    case state.backend.detect(state.backend_server, sequence, image) do
      :ok -> %{state | sequence: sequence, pending: source}
      # Busy or unavailable: skip this pair silently. The backend logs
      # the unavailable case once at startup; a per-frame log here
      # would be the loudest thing in the RingLogger.
      {:error, _reason} -> state
    end
  end

  @impl GenServer
  def handle_info(
        {:inference_detections, sequence, detections},
        %{sequence: sequence, pending: %Pair{} = pair} = state
      ) do
    positioned =
      detections
      |> select(state)
      |> Enum.map(&position(&1, pair, state))
      |> Enum.reject(&is_nil/1)
      |> outline(pair, state.outline_segments)

    Outputs.publish(
      {:detections, Detection.server(__MODULE__, state.name)},
      detections_message(state.name, pair, positioned)
    )

    {:noreply, %{state | pending: nil}}
  end

  def handle_info(
        {:inference_detections, sequence, detections},
        %{sequence: sequence, pending: %Frame{} = frame} = state
      ) do
    case detections |> select(state) |> Enum.map(&labelled(&1, state)) do
      [] ->
        publish(state, frame, [])
        {:noreply, %{state | pending: nil}}

      labelled ->
        awaiting = %{frame: frame, detections: labelled, timer: nil}
        state = %{state | pending: nil}

        if CameraSource.placeable?(state.camera),
          do: {:noreply, place_awaiting(awaiting, state, final: false)},
          else: {:noreply, place_frame(awaiting, nil, state)}
    end
  end

  # A reply for a pair no longer waited on.
  def handle_info({:inference_detections, _stale, _detections}, state), do: {:noreply, state}

  def handle_info({:pair_wait, timer}, %{awaiting: %{timer: timer} = awaiting} = state),
    do: {:noreply, place_awaiting(awaiting, state, final: true)}

  def handle_info(_message, state), do: {:noreply, state}

  defp select(detections, state) do
    detections
    |> Enum.filter(&(&1.score >= state.min_score))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(state.max_detections)
  end

  defp labelled(detection, state) do
    %{
      box: detection,
      class_id: detection.class_id,
      label: label(detection, state),
      score: detection.score
    }
  end

  defp label(detection, state),
    do: Enum.at(state.labels, detection.class_id, "class_#{detection.class_id}")

  # Places a camera frame's boxes once its pair is known, or waits for it, at most :pair_wait_ms.
  defp place_awaiting(%{frame: frame} = awaiting, state, final: final) do
    case CameraSource.match(state.camera, frame.capture_ns, final: final) do
      :wait when is_nil(awaiting.timer) ->
        timer = make_ref()
        Process.send_after(self(), {:pair_wait, timer}, state.pair_wait_ms)
        %{state | awaiting: %{awaiting | timer: timer}}

      :wait ->
        %{state | awaiting: awaiting}

      {:ok, pair} ->
        place_frame(awaiting, pair, note_match(state, pair))

      :none ->
        place_frame(awaiting, nil, note_match(state, nil))
    end
  end

  defp place_frame(%{frame: frame, detections: detections}, pair, state) do
    {placed, camera} =
      CameraSource.place(
        state.camera,
        detections,
        frame,
        pair,
        state.depth_sample_fraction,
        state.reprojection_stride
      )

    detections =
      Enum.map(placed, fn detection ->
        Map.merge(detection, %{
          outline: CameraSource.outline(detection.box),
          caption: caption(detection)
        })
      end)

    publish(state, frame, detections)
    %{state | camera: camera, awaiting: nil}
  end

  defp note_match(%{unmatched_logged: false} = state, nil) do
    Logger.warning(
      "detection pipeline #{state.name}: no stereo pair captured close enough to the camera " <>
        "#{state.camera.name}'s image, so its detections have no distance until one is"
    )

    %{state | unmatched_logged: true}
  end

  defp note_match(state, nil), do: state
  defp note_match(state, _pair), do: %{state | unmatched_logged: false}

  defp publish(state, source, detections),
    do:
      Outputs.publish(
        {:detections, Detection.server(__MODULE__, state.name)},
        detections_message(state.name, source, detections)
      )

  defp detections_message(:detection, pair, positioned), do: {:detections, pair, positioned}
  defp detections_message(name, pair, positioned), do: {:detections, pair, positioned, name}

  defp outline(positioned, pair, segments) do
    outlines = positioned |> Enum.map(& &1.box) |> Fusion.outlines(segments, pair)

    Enum.zip_with(positioned, outlines, fn detection, outline ->
      Map.merge(detection, %{outline: outline, caption: caption(detection)})
    end)
  end

  defp caption(%{z: nil} = detection),
    do: "#{detection.label} #{:erlang.float_to_binary(detection.score / 1, decimals: 2)}"

  defp caption(detection),
    do:
      "#{caption(%{detection | z: nil})} #{:erlang.float_to_binary(detection.z / 1, decimals: 2)}m"

  defp position(detection, %Pair{} = pair, state) do
    {width, height} = Pair.size(pair)

    case Fusion.median_depth(pair.depth, {width, height}, detection, state.depth_sample_fraction) do
      nil ->
        nil

      depth_m ->
        detection
        |> Fusion.unproject(
          depth_m,
          pair.geometry.principal_point,
          pair.geometry.focal_length_px
        )
        |> Map.merge(%{
          box: detection,
          class_id: detection.class_id,
          label: label(detection, state),
          score: detection.score,
          # One view cannot measure extent along the optical axis; a
          # thin slab marks where the surface is, not how deep it goes.
          depth: 0.1
        })
    end
  end
end
