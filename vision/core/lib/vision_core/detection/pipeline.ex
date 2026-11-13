defmodule VisionCore.Detection.Pipeline do
  @moduledoc """
  Detects objects on the stereo unit's pairs, or on a camera of its own,
  and places them in 3D: hands the rectified left image of every
  `:detect_every_n`-th `VisionCore.Stereo.Pair` to a
  `VisionCore.Detection.Backend`, fuses the boxes it returns with that
  pair's depth map, and publishes the result through
  `VisionCore.Outputs` under its `VisionCore.Exporter` output,
  `{:detections, name}` (`VisionCore.Detection.output/1`), as
  `{output, {pair, detections}}`.

  With `source: {:camera, name}` it detects on the frames of the camera
  of its own `name` instead, its default output, or with
  `source: {:camera, name, output}` on those of its output `output`
  (`VisionCore.Camera.Output`; see "A camera source" below), and publishes
  `{output, {frame, detections}}`, `frame` the
  `VisionCore.Camera.Frame` the boxes were found on, without its pixels.

  Subscribes to the pairs of `VisionCore.Stereo.Pipeline`, so it sees
  the pairs every other consumer does, rectified left image and metric
  depth included. On the stereo source, that is why detection is nearly
  free: the pixels are already decoded and rectified, the depth is
  already computed, and the accelerator is otherwise idle.

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
  input. Its boxes are placed with the depth of the stereo pair captured
  closest to the frame, projected into the camera's image through its
  calibration and pose (`VisionCore.Detection.CameraSource`), only for a
  frame with boxes. The stereo pipeline publishes a pair after the
  frame's boxes may be back, so they wait for it in a queue
  (`VisionCore.CameraPipeline`) while the next frames go to the backend,
  and leave it in capture order: at most `:pair_wait_ms`, and not at all
  while the stereo pairs have stalled, two pair periods without one.
  While 32 frames' boxes wait, the camera's frames are skipped. The
  boxes of a frame whose size the calibration cannot be projected at,
  such as one of another aspect ratio, wait for no pair.

  The calibration and the pose are read at start. A calibration
  committed through the camera's `set_camera_info` reaches the ROS 2
  exporter's `camera_info` at once, but the boxes are placed with the
  start-time calibration until the unit restarts.

  A box with no distance is kept: its position and size are `nil`, and
  its `:bearing` says where it is seen. Each detection is in the
  camera's optical frame, its `:box` and `:outline`, its four corners,
  in the frame's pixels, and has a `:bearing`, `{azimuth, elevation}` in
  radians, `nil` without a calibration. Its caption has its distance
  only when it has one: `"person 0.62"`.

  ## One inference in flight

  On the stereo source (`VisionCore.Detection.StereoPipeline`), one pair
  is in flight at a time, kept with the sequence number it was submitted
  under, and a reply is matched on that number. Every submission takes a
  new number, a refused one included, so a late reply to a call that
  timed out never matches a later pair. `:detect_every_n` counts the
  pairs, those that come while a submission is in flight included: the
  `n`th, `2n`th, `3n`th… of them are to be detected on. A pair that
  comes while a submission is in flight is skipped, and one the backend
  could not detect on, answered with `nil`, publishes nothing.

  On a camera source (`VisionCore.Detection.CameraPipeline`),
  `VisionCore.CameraPipeline` runs the pipeline: it detects on every
  `:detect_every_n`-th frame, one in flight at a time, the newest frame
  held meanwhile. A frame whose JPEG does not decode is skipped, which
  is logged once until one decodes.

  ## Options

    * `:name` (`:detection`) — the pipeline's name: it registers as
      `VisionCore.Pipelines.server(VisionCore.Detection.Pipeline, name)`
      and declares its parameter groups as `<name>.*`.
    * `:backend` (`VisionCore.Detection.Backend.Hailo`) — the detection
      backend module.
    * `:backend_server` (the `:backend` module) — the name the backend is
      registered under.
    * `:source` (`:stereo`) — the stereo pairs, `{:camera, name}`,
      the camera of its own `name` (`VisionCore.Camera.Unit`), or
      `{:camera, name, output}`, that camera's output `output`.
    * `:detect_every_n` (`1`) — run inference on every nth pair, or
      frame of a camera source (see "One inference in flight").
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
      boxes wait for the pair captured closest to it, and how far before
      the newest pair's capture the pairs are kept.
    * `:config` (the active `VisionCore.Config`) — the configuration the
      camera of a camera source is read from.
    * `:clock` (`System.monotonic_time/1` in nanoseconds) — the time the
      waits of a camera source are measured with, a function of no
      argument.

  `:detect_every_n` and `:reprojection_stride` are integers from 1 on,
  `:max_detections` and `:pair_wait_ms` from 0 on, and `:min_score` is a
  number: another value fails the start (`VisionCore.Options`).
  """
  alias VisionCore.{Detection, Pipelines}
  alias VisionCore.Detection.{CameraPipeline, StereoPipeline}
  alias VisionCore.{Options, Parameters}

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
                                  "pair_wait_ms, how long the boxes wait for that pair. The " <>
                                  "next images go to the detector meanwhile, and the boxes " <>
                                  "are published in the images' order; while the stereo " <>
                                  "pairs have stopped, they are published at once, with " <>
                                  "the pair already kept if one was captured within half " <>
                                  "a pair period of the image. A " <>
                                  "box with no depth in its middle, or out of the stereo " <>
                                  "pair's view, is kept without a distance, with its " <>
                                  "bearing. Watch the outlines and distances on the camera's " <>
                                  "video."

  @doc false
  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    registration = [name: Pipelines.server(__MODULE__, Detection.pipeline_name(opts))]

    case Keyword.get(opts, :source, :stereo) do
      camera when is_tuple(camera) -> CameraPipeline.start_link(opts, registration)
      _stereo -> StereoPipeline.start_link(opts, registration)
    end
  end

  @doc "The COCO class names, indexed by class id."
  def labels, do: @coco_labels

  @doc """
  What a detection pipeline keeps of `opts`, on either source: its
  `:name`, its `:source`, a camera's with its output, `nil` for the
  camera's default, its backend and the options of the module doc, each
  with its default. Raises `ArgumentError` on a value it cannot run
  with.
  """
  @spec settings(keyword()) :: map()
  def settings(opts) do
    backend = Keyword.get(opts, :backend, VisionCore.Detection.Backend.Hailo)

    %{
      name: Detection.pipeline_name(opts),
      source: source!(Keyword.get(opts, :source, :stereo)),
      backend: backend,
      backend_server: Keyword.get(opts, :backend_server, backend),
      detect_every_n: Options.integer!(opts, :detect_every_n, @default_detect_every_n, 1),
      labels: Keyword.get(opts, :labels, @coco_labels),
      min_score: Options.number!(opts, :min_score, @default_min_score),
      max_detections: Options.integer!(opts, :max_detections, @default_max_detections, 0),
      depth_sample_fraction:
        Keyword.get(opts, :depth_sample_fraction, @default_depth_sample_fraction),
      outline_segments: Keyword.get(opts, :outline_segments, @default_outline_segments),
      reprojection_stride:
        Options.integer!(opts, :reprojection_stride, @default_reprojection_stride, 1),
      pair_wait_ms: Options.integer!(opts, :pair_wait_ms, @default_pair_wait_ms, 0)
    }
  end

  defp source!(:stereo), do: :stereo
  defp source!({:camera, camera}), do: source!({:camera, camera, nil})

  defp source!({:camera, camera, output} = source) when is_atom(camera) and is_atom(output),
    do: source

  defp source!(source),
    do:
      raise(
        ArgumentError,
        "its :source is :stereo, {:camera, name}, a camera of its own, or " <>
          "{:camera, name, output}, one of its outputs, got #{inspect(source)}"
      )

  @doc """
  The detection pipeline's steps around the inference, for its
  settings (`settings/1`): their parameter groups, `<name>.input`, `<name>.filtering` and
  `<name>.placement` in the pipeline `name`, with their settings fixed at
  start. The backend declares the inference step itself
  (`inference_group/2`).
  """
  @spec groups(map()) :: [Parameters.group_declaration()]
  def groups(state) do
    source = state.source

    [
      Parameters.step(state.name, "input", "Input", 101, %{
        summary: input_summary(source),
        explanation: input_explanation(source),
        compute: Parameters.on_the_beam(),
        parameters: [
          build_parameter(state, :detect_every_n, detect_every_n_description(source))
        ]
      }),
      Parameters.step(state.name, "filtering", "Filtering", 103, %{
        summary: "Keeps the most confident detections.",
        explanation: @filtering_explanation,
        compute: Parameters.on_the_beam(),
        parameters: [
          build_parameter(state, :min_score, "Lowest score of a detection passed on"),
          build_parameter(state, :max_detections, "Most detections passed on per image")
        ]
      }),
      Parameters.step(state.name, "placement", "Placement", 104, %{
        summary: "Places each box in 3D with the median depth in its middle.",
        explanation: placement_explanation(source),
        compute: Parameters.on_the_beam(),
        parameters: placement_parameters(source, state)
      })
    ]
  end

  defp input_summary(:stereo),
    do: "Hands the rectified left image of every nth stereo pair to the detector."

  defp input_summary({:camera, camera, output}),
    do: "Hands every nth image of #{camera_text(camera, output)} to the detector."

  defp detect_every_n_description(:stereo), do: "Pairs per detection; 1 detects on every pair"

  defp detect_every_n_description({:camera, _camera, _output}),
    do: "Images per detection; 1 detects on every image"

  defp input_explanation(:stereo), do: @input_explanation

  defp input_explanation({:camera, camera, output}),
    do:
      "Takes the images of #{camera_text(camera, output)} and hands them to the detector, which " <>
        "shrinks each whole to its model's input. detect_every_n, fixed in the build, runs " <>
        "detection on one image out of n: a higher value leaves the accelerator and the " <>
        "processor more time, and updates the boxes less often. An image to detect on that " <>
        "arrives while the detector is still busy waits, the newest one only, and goes to the " <>
        "detector as soon as it is done."

  defp placement_explanation(:stereo), do: @placement_explanation
  defp placement_explanation({:camera, _camera, _output}), do: @camera_placement_explanation

  defp camera_text(camera, nil), do: "the camera #{camera}"
  defp camera_text(camera, output), do: "the camera #{camera}'s output #{output}"

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

        {:camera, _camera, _output} ->
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
  @spec inference_group(atom(), map()) :: Parameters.group_declaration()
  def inference_group(pipeline, fields),
    do: Parameters.step(pipeline, "inference", "Inference", 102, fields)

  defp build_parameter(state, key, description),
    do: VisionCore.Stereo.Parameters.build_parameter({key, Map.fetch!(state, key)}, description)

  @doc """
  The `detections` worth passing on: those scoring at least the
  pipeline's `:min_score`, its `:max_detections` at most, best first.
  """
  @spec select([Detection.Backend.detection()], map()) :: [Detection.Backend.detection()]
  def select(detections, settings) do
    detections
    |> Enum.filter(&(&1.score >= settings.min_score))
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(settings.max_detections)
  end

  @doc "The name of `detection`'s class among the pipeline's `:labels`, `class_<id>` without one."
  @spec label(Detection.Backend.detection(), map()) :: String.t()
  def label(detection, settings),
    do: Enum.at(settings.labels, detection.class_id, "class_#{detection.class_id}")

  @doc """
  What a viewer writes next to a placed `detection`: its label, its
  score and its distance, `"person 0.62 1.80m"`, without the distance
  when it has none.
  """
  @spec caption(map()) :: String.t()
  def caption(%{z: nil} = detection),
    do: "#{detection.label} #{:erlang.float_to_binary(detection.score / 1, decimals: 2)}"

  def caption(detection),
    do:
      "#{caption(%{detection | z: nil})} #{:erlang.float_to_binary(detection.z / 1, decimals: 2)}m"

  @doc """
  Publishes the pipeline's `detections` found on `source`, a stereo pair
  or a camera's frame, through `VisionCore.Outputs` (see the module
  doc).
  """
  @spec publish(map(), VisionCore.Stereo.Pair.t() | VisionCore.Camera.Frame.t(), [map()]) :: :ok
  def publish(settings, source, detections),
    do: VisionCore.Outputs.publish(output_key(settings), message(settings, source, detections))

  @doc "The `VisionCore.Outputs` key the pipeline publishes under."
  @spec output_key(map()) :: VisionCore.Outputs.key()
  def output_key(settings), do: Detection.output(settings.name)

  @doc "The message the pipeline publishes for the `detections` found on `source`."
  @spec message(map(), VisionCore.Stereo.Pair.t() | VisionCore.Camera.Frame.t(), [map()]) ::
          tuple()
  def message(%{name: name}, source, detections),
    do: {Detection.output(name), {source, detections}}
end
