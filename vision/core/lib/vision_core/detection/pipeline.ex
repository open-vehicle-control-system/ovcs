defmodule VisionCore.Detection.Pipeline do
  @moduledoc """
  Detects objects on the stereo unit's pairs and places them in 3D:
  hands the rectified left image of every `:detect_every_n`-th
  `VisionCore.Stereo.Pair` to a `VisionCore.Detection.Backend`, fuses
  the boxes it returns with that pair's depth map, and sends the result
  to its listeners as `{:detections, pair, detections}`.

  Registers as a listener on `VisionCore.Stereo.Pipeline`, so it sees
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
  and `:score`.

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
  """
  use GenServer

  alias VisionCore.Detection.Fusion
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

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The COCO class names, indexed by class id."
  def labels, do: @coco_labels

  @doc "Sends every later `{:detections, pair, detections}` to `listener` as a cast."
  def register_listener(server, listener),
    do: GenServer.cast(server, {:register_listener, listener})

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
      listeners: [],
      sequence: 0,
      pair_count: 0,
      # The pair submitted with the in-flight inference: its boxes belong to that depth map.
      pending: nil
    }

    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare([group(state)])

    VisionCore.Stereo.Pipeline.register_listener(VisionCore.Stereo.Pipeline, self())
    {:ok, state}
  end

  @doc "The detection's parameter group for a running `state`: its settings, fixed at start."
  @spec group(map()) :: VisionCore.Parameters.group_declaration()
  def group(state) do
    %{
      id: "detection",
      name: "Detection",
      summary: "Object detection on the rectified left image, placed with the depth map.",
      kind: :component,
      placement: :side,
      position: 101,
      parameters:
        Enum.map(
          [:detect_every_n, :min_score, :max_detections, :depth_sample_fraction],
          &VisionCore.Stereo.Parameters.build_parameter({&1, Map.fetch!(state, &1)})
        )
    }
  end

  @impl GenServer
  def handle_cast({:register_listener, listener}, state),
    do: {:noreply, %{state | listeners: state.listeners ++ [listener]}}

  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    pair_count = state.pair_count + 1
    state = %{state | pair_count: pair_count}

    cond do
      rem(pair_count, state.detect_every_n) != 0 -> {:noreply, state}
      is_nil(pair.left) or is_nil(pair.depth_m) -> {:noreply, state}
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

    Enum.each(state.listeners, &GenServer.cast(&1, {:detections, pair, positioned}))
    {:noreply, %{state | pending: nil}}
  end

  # A reply for a pair no longer waited on.
  def handle_info({:inference_detections, _stale, _detections}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp position(detection, %Pair{} = pair, state) do
    case Fusion.median_depth(pair.depth_m, detection, state.depth_sample_fraction) do
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
