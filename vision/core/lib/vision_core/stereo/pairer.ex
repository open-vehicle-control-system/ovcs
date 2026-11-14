defmodule VisionCore.Stereo.Pairer do
  @moduledoc """
  Pairs the two camera drivers' frames by capture time and feeds the
  pairs to `VisionCore.Stereo.Pipeline`, one at a time.

  Both sides arrive independently; the last few frames of each are kept,
  and the pair submitted is the one whose `Frame.capture_ns` are closest,
  the newest among those within a millisecond of each other, within
  `:pair_tolerance_ms`. The newest frame
  of each side is not a pair: one side's next frame often lands before
  the other's, and pairing them mixes two capture instants.

  While the pipeline is processing a pair, ready pairs are dropped rather
  than queued: a backlog would only add latency to a live measurement.
  The next pair goes in as soon as the pipeline reports the previous one
  done, failed or not.

  It also measures how far apart the two cameras capture, on every frame
  they deliver (`VisionCore.Stereo.Sync`), which `sync/1` answers.

  ## Options

    * `:cameras` (required) — `[{driver_module, "left"}, {driver_module, "right"}]`.
    * `:pipeline` (`VisionCore.Stereo.Pipeline`) — the pipeline server.
    * `:pair_tolerance_ms` (33) — the largest capture time gap of a
      pair, an integer from 0 to 1000; wide enough for unsynchronised
      USB cameras with a stable phase offset. It changes while the
      pairer runs (`put_pair_tolerance_ms/2`), as the vision parameter
      `<prefix>.pairing.pair_tolerance_ms`.
    * `:fps` (30) — the cameras' frame rate: frames half a period apart
      or more are not measured as a pair of the sync.
  """
  use GenServer
  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.{Outputs, Settings}
  alias VisionCore.Stereo.{Pipeline, StageTimer, Sync}

  @setting_specs [
    pair_tolerance_ms: %{
      type: :integer,
      range: {0, 1000},
      default: 33,
      description: "Largest capture time gap between the two frames of a pair, in ms"
    }
  ]
  @ns_per_ms 1_000_000
  @default_fps 30
  # A few frame periods: enough to find the closest pair.
  @frames_kept_per_side 4
  # Gaps closer than this are equally good: the newest pair is the one with least latency.
  @gap_resolution_ns 1_000_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  How far apart the cameras captured their recent pairs of frames; see
  `VisionCore.Stereo.Sync.summary/2`.
  """
  @spec sync(GenServer.server()) :: Sync.summary()
  def sync(server \\ __MODULE__), do: GenServer.call(server, :sync)

  @doc "The pairer's setting, `:pair_tolerance_ms`: its type, the values it takes and its default."
  @spec setting_specs() :: Settings.specs()
  def setting_specs, do: @setting_specs

  @doc "The largest capture time gap of a pair, in ms."
  @spec pair_tolerance_ms(GenServer.server()) :: non_neg_integer()
  def pair_tolerance_ms(server \\ __MODULE__), do: GenServer.call(server, :pair_tolerance_ms)

  @doc """
  Changes the largest capture time gap of a pair to `tolerance_ms`, from
  the next pair on, or says why it is refused.
  """
  @spec put_pair_tolerance_ms(GenServer.server(), term()) :: :ok | {:error, String.t()}
  def put_pair_tolerance_ms(server \\ __MODULE__, tolerance_ms),
    do: GenServer.call(server, {:put_pair_tolerance_ms, tolerance_ms})

  @impl GenServer
  def init(opts) do
    cameras = Keyword.fetch!(opts, :cameras)
    pipeline = Keyword.get(opts, :pipeline, Pipeline)
    %{pair_tolerance_ms: tolerance_ms} = Settings.init!(@setting_specs, opts)

    for side <- ["left", "right"] do
      {driver, ^side} = List.keyfind(cameras, side, 1) || raise "no #{side} camera in :cameras"
      :ok = Outputs.subscribe({:camera_frame, driver.name_for(side)})
    end

    Logger.info("#{__MODULE__} pairing within #{tolerance_ms} ms")

    {:ok,
     %{
       pipeline: pipeline,
       pair_tolerance_ns: tolerance_ms * @ns_per_ms,
       left_frames: [],
       right_frames: [],
       awaiting_pair: false,
       submitted_at_ns: nil,
       sync: Sync.new(Keyword.get(opts, :fps, @default_fps)),
       timer: StageTimer.new(window: 30, label: "pairer")
     }}
  end

  @impl GenServer
  def handle_call(:sync, _from, state),
    do: {:reply, Sync.summary(state.sync, System.monotonic_time(:millisecond)), state}

  def handle_call(:pair_tolerance_ms, _from, state),
    do: {:reply, div(state.pair_tolerance_ns, @ns_per_ms), state}

  def handle_call({:put_pair_tolerance_ms, tolerance_ms}, _from, state) do
    case Settings.put(@setting_specs, %{pair_tolerance_ms: nil}, :pair_tolerance_ms, tolerance_ms) do
      {:ok, %{pair_tolerance_ms: tolerance_ms}} ->
        {:reply, :ok, %{state | pair_tolerance_ns: tolerance_ms * @ns_per_ms}}

      {:error, _reason} = refusal ->
        {:reply, refusal, state}
    end
  end

  @impl GenServer
  def handle_cast({:camera_frame, %Frame{} = frame}, state),
    do: {:noreply, state |> measure(frame) |> keep(frame) |> maybe_submit()}

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:stereo_pipeline_ready, state) do
    round_trip_ns =
      if state.submitted_at_ns,
        do: System.monotonic_time(:nanosecond) - state.submitted_at_ns,
        else: 0

    timer = state.timer |> StageTimer.record(:pipeline, round_trip_ns) |> StageTimer.tick()

    # Frames may have arrived while the pipeline was busy: submit a ready pair now.
    {:noreply, maybe_submit(%{state | awaiting_pair: false, submitted_at_ns: nil, timer: timer})}
  end

  defp measure(state, %Frame{label: label, capture_ns: capture_ns})
       when label in ["left", "right"] do
    side = String.to_existing_atom(label)
    now_ms = System.monotonic_time(:millisecond)
    {_offset_ms, sync} = Sync.add(state.sync, side, capture_ns, now_ms)
    %{state | sync: sync}
  end

  defp measure(state, _frame), do: state

  defp keep(state, %Frame{label: "left"} = frame),
    do: %{state | left_frames: Enum.take([frame | state.left_frames], @frames_kept_per_side)}

  defp keep(state, %Frame{label: "right"} = frame),
    do: %{state | right_frames: Enum.take([frame | state.right_frames], @frames_kept_per_side)}

  defp keep(state, _frame), do: state

  defp maybe_submit(state) do
    case ready_pair(state) do
      :not_ready ->
        state

      {:out_of_tolerance, delta_ns} ->
        record_drop(state, delta_ns, :drop_tolerance)

      {:ok, _left, _right, delta_ns} when state.awaiting_pair ->
        record_drop(state, delta_ns, :drop_busy)

      {:ok, left, right, delta_ns} ->
        Pipeline.submit(state.pipeline, left, right)

        %{
          state
          | left_frames: newer_than(state.left_frames, left),
            right_frames: newer_than(state.right_frames, right),
            awaiting_pair: true,
            submitted_at_ns: System.monotonic_time(:nanosecond),
            timer: StageTimer.record(state.timer, :pair_delta, delta_ns)
        }
    end
  end

  defp record_drop(state, delta_ns, counter) do
    update_in(state.timer, fn timer ->
      timer |> StageTimer.record(:pair_delta, delta_ns) |> StageTimer.bump(counter)
    end)
  end

  @doc false
  def ready_pair(%{left_frames: []}), do: :not_ready
  def ready_pair(%{right_frames: []}), do: :not_ready

  def ready_pair(%{
        left_frames: left_frames,
        right_frames: right_frames,
        pair_tolerance_ns: tolerance_ns
      }) do
    candidates =
      for left <- left_frames, right <- right_frames do
        delta_ns = abs(left.capture_ns - right.capture_ns)

        {div(delta_ns, @gap_resolution_ns), -max(left.capture_ns, right.capture_ns), delta_ns,
         left, right}
      end

    # Closest capture times first, then the newest.
    {_gap, _newest, delta_ns, left, right} =
      Enum.min_by(candidates, fn {gap, newest, _delta_ns, _left, _right} -> {gap, newest} end)

    if delta_ns <= tolerance_ns do
      {:ok, left, right, delta_ns}
    else
      {:out_of_tolerance, delta_ns}
    end
  end

  # Frames taken after the submitted one: older ones can no longer pair.
  defp newer_than(frames, %Frame{capture_ns: capture_ns}),
    do: Enum.filter(frames, &(&1.capture_ns > capture_ns))
end
