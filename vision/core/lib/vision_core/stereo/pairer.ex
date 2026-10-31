defmodule VisionCore.Stereo.Pairer do
  @moduledoc """
  Pairs the two camera drivers' frames by capture time and feeds the
  pairs to `VisionCore.Stereo.Pipeline`, one at a time.

  Both sides arrive independently; the last few frames of each are kept,
  and the pair submitted is the one whose `Frame.capture_ns` are closest,
  the newest among equals, within `:pair_tolerance_ms`. The newest frame
  of each side is not a pair: one side's next frame often lands before
  the other's, and pairing them mixes two capture instants.

  While the pipeline is processing a pair, ready pairs are dropped rather
  than queued: a backlog would only add latency to a live measurement.
  The next pair goes in as soon as the pipeline reports the previous one
  done, failed or not.

  ## Options

    * `:cameras` (required) — `[{driver_module, "left"}, {driver_module, "right"}]`.
    * `:pipeline` (`VisionCore.Stereo.Pipeline`) — the pipeline server.
    * `:pair_tolerance_ms` (33) — the largest capture time gap of a
      pair; wide enough for unsynchronised USB cameras with a stable
      phase offset.
  """
  use GenServer
  require Logger

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{Pipeline, StageTimer}

  @default_pair_tolerance_ms 33
  # A few frame periods: enough to find the closest pair.
  @frames_kept_per_side 4

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl GenServer
  def init(opts) do
    cameras = Keyword.fetch!(opts, :cameras)
    pipeline = Keyword.get(opts, :pipeline, Pipeline)
    tolerance_ms = Keyword.get(opts, :pair_tolerance_ms, @default_pair_tolerance_ms)

    for side <- ["left", "right"] do
      {driver, ^side} = List.keyfind(cameras, side, 1) || raise "no #{side} camera in :cameras"
      driver.register_listener(driver.name_for(side), self())
    end

    Logger.info("#{__MODULE__} pairing within #{tolerance_ms} ms")

    {:ok,
     %{
       pipeline: pipeline,
       pair_tolerance_ns: tolerance_ms * 1_000_000,
       left_frames: [],
       right_frames: [],
       awaiting_pair: false,
       submitted_at_ns: nil,
       timer: StageTimer.new(window: 30, label: "pairer")
     }}
  end

  @impl GenServer
  def handle_cast({:camera_frame, %Frame{} = frame}, state),
    do: {:noreply, state |> keep(frame) |> maybe_submit()}

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
        {abs(left.capture_ns - right.capture_ns), -max(left.capture_ns, right.capture_ns), left,
         right}
      end

    # Closest capture times first, then the newest.
    {delta_ns, _newest, left, right} =
      Enum.min(candidates, fn {delta_a, newest_a, _, _}, {delta_b, newest_b, _, _} ->
        {delta_a, newest_a} <= {delta_b, newest_b}
      end)

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
