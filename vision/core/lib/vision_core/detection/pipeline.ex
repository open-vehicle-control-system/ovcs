defmodule VisionCore.Detection.Pipeline do
  @moduledoc """
  Detects objects on the stereo unit's pairs and places them in 3D:
  hands the rectified left image of every `:detect_every_n`-th
  `VisionCore.Stereo.Pair` to a `VisionCore.Detection.Backend`, fuses
  the boxes it returns with that pair's depth map, and publishes the
  result as `{:detections, pair, detections}` through
  `VisionCore.Outputs`, under `{:detections, VisionCore.Detection.Pipeline}`.

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

  ## One inference in flight

  Only one submitted pair is held, and a reply is matched on the
  current sequence number. That relies on the backend answering
  `{:error, :busy}` while an inference is in flight, so the sequence
  only advances on an accepted frame; a backend that accepted
  overlapping requests would have its earlier replies discarded as
  stale.

  ## Options

    * `:backend` (`VisionCore.Detection.Backend.Hailo`) — the detection
      backend module, which is also its registered name.
    * `:detect_every_n` (`1`) — run inference on every nth pair.
    * `:labels` (COCO 80) — class id to name.
    * `:min_score` (`0.4`) — the backend filters at its own threshold
      too; this is the floor for what is passed on.
    * `:max_detections` (`20`).
    * `:depth_sample_fraction` (`0.5`) — central fraction of the box
      used for the depth median.
    * `:outline_segments` (`4`) — pieces each edge of an outline is cut
      into.
  """
  use GenServer

  alias VisionCore.Detection.Fusion
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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The COCO class names, indexed by class id."
  def labels, do: @coco_labels

  @impl GenServer
  def init(opts) do
    state = %{
      # Doubles as the server name: every backend registers under its own module.
      backend: Keyword.get(opts, :backend, VisionCore.Detection.Backend.Hailo),
      detect_every_n: Keyword.get(opts, :detect_every_n, @default_detect_every_n),
      labels: Keyword.get(opts, :labels, @coco_labels),
      min_score: Keyword.get(opts, :min_score, @default_min_score),
      max_detections: Keyword.get(opts, :max_detections, @default_max_detections),
      depth_sample_fraction:
        Keyword.get(opts, :depth_sample_fraction, @default_depth_sample_fraction),
      outline_segments: Keyword.get(opts, :outline_segments, @default_outline_segments),
      sequence: 0,
      pair_count: 0,
      # The pair submitted with the in-flight inference: its boxes belong to that depth map.
      pending: nil
    }

    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare(groups(state))

    :ok = Outputs.subscribe({:stereo_pair, VisionCore.Stereo.Pipeline})
    {:ok, state}
  end

  @doc """
  The detection pipeline's steps around the inference, for a running
  `state`: their parameter groups, with their settings fixed at start. The
  backend declares the inference step itself (`inference_group/1`).
  """
  @spec groups(map()) :: [VisionCore.Parameters.group_declaration()]
  def groups(state) do
    [
      step("input", "Input", 101, %{
        summary: "Hands the rectified left image of every nth stereo pair to the detector.",
        explanation: @input_explanation,
        compute: @on_the_beam,
        parameters: [
          build_parameter(state, :detect_every_n, "Pairs per detection; 1 detects on every pair")
        ]
      }),
      step("filtering", "Filtering", 103, %{
        summary: "Keeps the most confident detections.",
        explanation: @filtering_explanation,
        compute: @on_the_beam,
        parameters: [
          build_parameter(state, :min_score, "Lowest score of a detection passed on"),
          build_parameter(state, :max_detections, "Most detections passed on per image")
        ]
      }),
      step("placement", "Placement", 104, %{
        summary: "Places each box in 3D with the median depth in its middle.",
        explanation: @placement_explanation,
        compute: @on_the_beam,
        parameters: [
          build_parameter(
            state,
            :depth_sample_fraction,
            "Share of the box's width and height whose depths are sampled"
          )
        ]
      })
    ]
  end

  @doc """
  The detection pipeline's inference step, between its input and its
  filtering. The backend running the model declares it, `fields` giving
  its summary, explanation, compute and parameters.
  """
  @spec inference_group(map()) :: VisionCore.Parameters.group_declaration()
  def inference_group(fields), do: step("inference", "Inference", 102, fields)

  defp step(id, name, position, fields) do
    Map.merge(
      %{
        id: "detection.#{id}",
        name: name,
        kind: :stage,
        pipeline: :detection,
        position: position
      },
      fields
    )
  end

  defp build_parameter(state, key, description),
    do: VisionCore.Stereo.Parameters.build_parameter({key, Map.fetch!(state, key)}, description)

  @impl GenServer
  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    pair_count = state.pair_count + 1
    state = %{state | pair_count: pair_count}

    cond do
      rem(pair_count, state.detect_every_n) != 0 -> {:noreply, state}
      is_nil(pair.left) or is_nil(pair.depth) -> {:noreply, state}
      true -> {:noreply, submit(pair, state)}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  # Overwrites `pending`; see "One inference in flight" in the moduledoc.
  defp submit(pair, state) do
    sequence = state.sequence + 1

    case state.backend.detect(state.backend, sequence, pair.left) do
      :ok -> %{state | sequence: sequence, pending: pair}
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
      |> Enum.filter(&(&1.score >= state.min_score))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(state.max_detections)
      |> Enum.map(&position(&1, pair, state))
      |> Enum.reject(&is_nil/1)
      |> outline(pair, state.outline_segments)

    Outputs.publish({:detections, __MODULE__}, {:detections, pair, positioned})
    {:noreply, %{state | pending: nil}}
  end

  # A reply for a pair no longer waited on.
  def handle_info({:inference_detections, _stale, _detections}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp outline(positioned, pair, segments) do
    outlines = positioned |> Enum.map(& &1.box) |> Fusion.outlines(segments, pair)

    Enum.zip_with(positioned, outlines, fn detection, outline ->
      Map.merge(detection, %{outline: outline, caption: caption(detection)})
    end)
  end

  defp caption(detection) do
    "#{detection.label} #{:erlang.float_to_binary(detection.score / 1, decimals: 2)} " <>
      "#{:erlang.float_to_binary(detection.z / 1, decimals: 2)}m"
  end

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
          label: Enum.at(state.labels, detection.class_id, "class_#{detection.class_id}"),
          score: detection.score,
          # One view cannot measure extent along the optical axis; a
          # thin slab marks where the surface is, not how deep it goes.
          depth: 0.1
        })
    end
  end
end
