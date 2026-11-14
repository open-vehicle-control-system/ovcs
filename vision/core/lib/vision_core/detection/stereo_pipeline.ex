defmodule VisionCore.Detection.StereoPipeline do
  @moduledoc """
  A `VisionCore.Detection.Pipeline` on the stereo pairs: hands the
  rectified left image of every `:detect_every_n`-th pair to the
  backend, one in flight at a time, and places the boxes it returns
  with that pair's depth, which lines up with the image pixel for pixel
  (`VisionCore.Detection.Fusion`). See `VisionCore.Detection.Pipeline`
  for what it publishes, its options and its steps' times.
  """
  use GenServer

  alias VisionCore.Detection.{Fusion, Pipeline}
  alias VisionCore.{Outputs, StageTimes}
  alias VisionCore.Stereo.Pair

  @doc "Starts the pipeline; `start_options` are `GenServer.start_link/3`'s."
  @spec start_link(keyword(), keyword()) :: GenServer.on_start()
  def start_link(opts, start_options), do: GenServer.start_link(__MODULE__, opts, start_options)

  @impl GenServer
  def init(opts) do
    settings = Pipeline.settings(opts)

    state =
      Map.merge(settings, %{
        # The sequence of the last submission, accepted or not.
        sequence: 0,
        pair_count: 0,
        # `{sequence, pair, submitted_ns}`: the pair of the in-flight inference, to which its boxes belong.
        pending: nil,
        clock: Keyword.get(opts, :clock, &monotonic_ns/0),
        times: StageTimes.new(Pipeline.stages())
      })

    if Process.whereis(VisionCore.Parameters),
      do: :ok = VisionCore.Parameters.declare(Pipeline.groups(settings))

    :ok = Outputs.subscribe({:stereo_pair, VisionCore.Stereo.Pipeline})
    {:ok, state}
  end

  defp monotonic_ns, do: System.monotonic_time(:nanosecond)

  @impl GenServer
  def handle_call(:stage_times, _from, state),
    do: {:reply, state.times, %{state | times: StageTimes.reset(state.times)}}

  @impl GenServer
  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    pair_count = state.pair_count + 1
    state = %{state | pair_count: pair_count}

    cond do
      rem(pair_count, state.detect_every_n) != 0 -> {:noreply, state}
      is_nil(pair.left) or is_nil(pair.depth) -> {:noreply, state}
      not is_nil(state.pending) -> {:noreply, state}
      true -> {:noreply, submit(pair, state)}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  defp submit(pair, state) do
    sequence = state.sequence + 1
    state = %{state | sequence: sequence}
    started_ns = state.clock.()

    case state.backend.detect(state.backend_server, sequence, pair.left) do
      :ok ->
        submitted_ns = state.clock.()
        time(%{state | pending: {sequence, pair, submitted_ns}}, :input, started_ns, submitted_ns)

      # Busy or unavailable: the backend logs the unavailable case once.
      {:error, _reason} ->
        state
    end
  end

  @impl GenServer
  def handle_info(
        {:inference_detections, sequence, nil},
        %{pending: {sequence, _pair, _submitted_ns}} = state
      ),
      do: {:noreply, %{state | pending: nil}}

  def handle_info(
        {:inference_detections, sequence, detections},
        %{pending: {sequence, pair, submitted_ns}} = state
      ) do
    replied_ns = state.clock.()
    selected = Pipeline.select(detections, state)
    selected_ns = state.clock.()

    positioned =
      selected
      |> Enum.map(&position(&1, pair, state))
      |> Enum.reject(&is_nil/1)
      |> outline(pair, state.outline_segments)

    placed_ns = state.clock.()
    Pipeline.publish(state, pair, positioned)

    state =
      state
      |> time(:inference, submitted_ns, replied_ns)
      |> time(:filtering, replied_ns, selected_ns)
      |> time(:placement, selected_ns, placed_ns)

    {:noreply, %{state | pending: nil}}
  end

  # A reply for a pair no longer waited on.
  def handle_info({:inference_detections, _stale, _detections}, state), do: {:noreply, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp time(state, stage, from_ns, to_ns),
    do: %{state | times: StageTimes.add(state.times, stage, (to_ns - from_ns) / 1_000_000)}

  defp outline(positioned, pair, segments) do
    outlines = positioned |> Enum.map(& &1.box) |> Fusion.outlines(segments, pair)

    Enum.zip_with(positioned, outlines, fn detection, outline ->
      Map.merge(detection, %{outline: outline, caption: Pipeline.caption(detection)})
    end)
  end

  defp position(detection, pair, state) do
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
          label: Pipeline.label(detection, state),
          score: detection.score,
          # One view cannot measure extent along the optical axis; a
          # thin slab marks where the surface is, not how deep it goes.
          depth: 0.1
        })
    end
  end
end
