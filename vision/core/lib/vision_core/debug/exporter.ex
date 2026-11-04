defmodule VisionCore.Debug.Exporter do
  @moduledoc """
  Records what the stereo unit sees and computes over a short burst, with
  the state it was in, as one zip a tuner downloads to compare the unit's
  results before and after a change of parameters
  (`VisionCore.Debug.Export` describes the zip). A `VisionCore.Exporter`,
  which `VisionCore.Exporters` lists as `debug`, "Debug"; a vehicle
  enables it by listing `{VisionCore.Debug.Exporter, []}` among its
  composer's `exporters:`.

  It reads the stereo unit's pairs, and its detections when the
  configuration has a detector. Without a stereo unit it is not started
  (`check/1`). Between exports it does nothing with them.

  ## The export action

  `export` answers `{:file, filename, "application/zip", zip}`. One export
  runs at a time: another asked for meanwhile is answered
  `{:error, :busy}`. The status is "Exporting" from the request until the
  zip is answered, "Ready" otherwise.

    1. **Settle.** While the last change (`:last_change`) is under
       `:settle_ms` old, the export waits until it is that old, and
       checks again then: the temporal filter carries history.
    2. **Burst.** It records the pairs the pipeline publishes for at least
       `:burst_ms` and at least `:burst_pairs` pairs, whichever ends
       later, the status snapshots whose window falls inside it, and the
       detections published during it. The runner hands over only the
       newest pair waiting (`VisionCore.Exporter.Runner`), so a pair can be
       skipped; a longer `intervalMs` shows where.
    3. **Answer.** It then collects the unit's state (`:unit_state`),
       encodes the export, off the runner, and answers. An export that
       raises, as on a unit whose stages leave the last pair without
       images, disparity or depth, answers `{:error, {:failed, message}}`.

  `:deadline_ms` after the request, an export whose burst has not ended
  answers `{:error, {:timeout, message}}`, naming how many pairs came;
  nothing partial is answered. An export whose caller has gone runs on
  to its end, and the exporter is then ready again.

  ## What a recording holds

    * Each burst pair's capture time, the interval since the previous
      burst pair's, `:device_ms`, `:sharpness`, `:alignment`, `:metrics`
      and `:stage_ms`, and the raw frames of the first `:frames_kept`.
    * The last pair, whole.
    * The `VisionCore.Status` snapshots that arrive at least
      `:snapshot_delay_ms` after the burst starts: each describes the
      second before it, so an earlier one describes the time before the
      burst. And whether the status could be subscribed to.
    * The detections, each publication as its pair's `captureNs` and its
      detections with the fields of the API's detections event: `label`,
      `score`, `distanceM` and `outline`, the `[x, y]` vertices as
      fractions of the left image's width and height.
    * The time the burst started, how long before it the last change
      was, and whether `:last_change` moved between the burst's start and
      its end (`changesDuringBurst`, 1 or 0).
    * The depth coloured as the dashboard colours it, blue at infinity
      whatever range the dashboard shows, so that the colours of two
      exports compare.

  ## Options

    * `:burst_pairs` (`30`) — the fewest pairs a burst records.
    * `:burst_ms` (`3_000`) — the shortest time a burst lasts.
    * `:settle_ms` (`2_000`) — how old the last change must be for a
      burst to start.
    * `:deadline_ms` (`30_000`) — the time from the request to the end of
      the burst.
    * `:frames_kept` (`30`) — how many of the burst's first pairs keep
      their raw frames.
    * `:snapshot_delay_ms` (`1_000`) — how long after the burst starts a
      status snapshot must arrive to be kept: the window a snapshot
      describes.
    * `:last_change` — `(-> integer() | nil)`, the monotonic time in
      milliseconds of the last change to what the stages compute or the
      cameras deliver; by default the later of the stereo pipeline's
      (`VisionCore.Stereo.Pipeline.last_change/1`) and
      `VisionCore.Parameters.last_change/1`, leaving out one that does not
      answer.
    * `:unit_state` — `(-> map())`, the unit's `:firmware`, `:parameters`,
      `:configuration`, `:calibration` and `:hostname`, as
      `VisionCore.Debug.Export` takes them; by default
      `VisionCore.Firmware.current/0`, `VisionCore.Parameters.groups/0`,
      `VisionCore.settings/0`, the stereo unit's calibration files
      (`VisionCore.Stereo.Supervisor.camera_options/1`) and
      `:inet.gethostname/0`.
    * `:status` — `{subscribe, unsubscribe}`, the functions that start and
      stop the runner's `{:vision_status, snapshot}` messages, each called
      with the runner's pid from a process of its own, since Status
      answers a subscription by asking each exporter's runner for its
      status; `VisionCore.Status.subscribe/1` and `unsubscribe/1` by
      default. A subscribe that exits leaves the export without snapshots.
    * `:jpeg_codec` (`VisionCore.Jpeg`) and `:config` (the active
      `VisionCore.Config`) — the `VisionCore.Jpeg` instance the coloured
      depth is encoded on, without which it is left out, and the
      configuration, which `VisionCore.Exporters` gives.
  """
  @behaviour VisionCore.Exporter

  alias VisionCore.{Firmware, Parameters, Preview, Status}
  alias VisionCore.Debug.Export
  alias VisionCore.Stereo.{Pair, Pipeline}
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor

  @default_burst_pairs 30
  @default_burst_ms 3_000
  @default_settle_ms 2_000
  @default_deadline_ms 30_000
  @default_frames_kept 30
  @default_snapshot_delay_ms 1_000
  @depth_range_m 0.0
  @last_pair_fields [:left, :right, :disparity_bytes, :depth]

  @impl VisionCore.Exporter
  def describe(_options), do: %{id: :debug, name: "Debug"}

  @impl VisionCore.Exporter
  def check(options) do
    if VisionCore.Exporter.output_key(:stereo_pair, config(options)),
      do: :ok,
      else: {:error, "no stereo unit to export"}
  end

  @impl VisionCore.Exporter
  def outputs(options) do
    if detector?(config(options)), do: [:stereo_pair, :detections], else: [:stereo_pair]
  end

  @impl VisionCore.Exporter
  def actions(_options),
    do: [
      %{
        name: :export,
        label: "Export",
        description: "A burst of pairs and the unit's state, as a zip"
      }
    ]

  @impl VisionCore.Exporter
  def init(options) do
    config = config(options)
    pipeline = pipeline_name(config)

    {:ok,
     %{
       burst_pairs: Keyword.get(options, :burst_pairs, @default_burst_pairs),
       burst_ms: Keyword.get(options, :burst_ms, @default_burst_ms),
       settle_ms: Keyword.get(options, :settle_ms, @default_settle_ms),
       deadline_ms: Keyword.get(options, :deadline_ms, @default_deadline_ms),
       frames_kept: Keyword.get(options, :frames_kept, @default_frames_kept),
       snapshot_delay_ms: Keyword.get(options, :snapshot_delay_ms, @default_snapshot_delay_ms),
       last_change: Keyword.get(options, :last_change, fn -> last_change(pipeline) end),
       unit_state: Keyword.get(options, :unit_state, fn -> unit_state(config) end),
       status: Keyword.get(options, :status, {&Status.subscribe/1, &Status.unsubscribe/1}),
       jpeg_codec: Keyword.get(options, :jpeg_codec, VisionCore.Jpeg),
       reads_detections: detector?(config),
       recording: nil
     }}
  end

  defp config(options) do
    Keyword.get_lazy(options, :config, &VisionCore.Application.active_config/0) ||
      %VisionCore.Config{}
  end

  defp detector?(config), do: VisionCore.Exporter.output_key(:detections, config) != nil

  defp pipeline_name(config) do
    case VisionCore.Exporter.output_key(:stereo_pair, config) do
      {:stereo_pair, pipeline} -> pipeline
      nil -> nil
    end
  end

  @impl VisionCore.Exporter
  def status(%{recording: nil}), do: {:ok, "Ready"}
  def status(_state), do: {:ok, "Exporting"}

  @impl VisionCore.Exporter
  def handle_action(:export, _params, _from, %{recording: %{}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_action(:export, _params, from, state) do
    reference = make_ref()
    deadline = Process.send_after(self(), {__MODULE__, :deadline, reference}, state.deadline_ms)
    recording = %{reference: reference, from: from, phase: :settling, deadline: deadline}
    {:noreply, settle(%{state | recording: recording})}
  end

  @impl VisionCore.Exporter
  def handle_output(:stereo_pair, %Pair{} = pair, %{recording: %{phase: :burst}} = state),
    do: {:ok, state |> record_pair(pair) |> finish_when_done()}

  def handle_output(:detections, {pair, detections}, %{recording: %{phase: :burst}} = state) do
    frame = pair.left_frame
    published = {Pair.capture_ns(pair), {frame.width, frame.height}, detections}
    {:ok, update_in(state.recording.detections, &[published | &1])}
  end

  def handle_output(_output, _value, state), do: {:ok, state}

  @impl VisionCore.Exporter
  def handle_info(
        {__MODULE__, :settled, reference},
        %{recording: %{reference: reference, phase: :settling}} = state
      ),
      do: {:ok, settle(state)}

  def handle_info(
        {__MODULE__, :burst_elapsed, reference},
        %{recording: %{reference: reference, phase: :burst}} = state
      ),
      do: {:ok, state |> put_in([:recording, :duration_reached], true) |> finish_when_done()}

  def handle_info(
        {__MODULE__, :deadline, reference},
        %{recording: %{reference: reference, phase: phase}} = state
      )
      when phase in [:settling, :burst],
      do: {:ok, time_out(state)}

  def handle_info(
        {__MODULE__, :answered, reference},
        %{recording: %{reference: reference, phase: :answering}} = state
      ),
      do: {:ok, %{state | recording: nil}}

  def handle_info(
        {__MODULE__, :status_subscribed, reference, subscribed},
        %{recording: %{reference: reference, phase: :burst}} = state
      ),
      do: {:ok, update_in(state.recording.status_available, &(&1 or subscribed))}

  def handle_info({:vision_status, snapshot}, %{recording: %{phase: :burst}} = state),
    do: {:ok, record_snapshot(state, snapshot)}

  def handle_info(_message, state), do: {:ok, state}

  defp settle(%{recording: recording} = state) do
    changed_ms = state.last_change.()
    age_ms = if is_integer(changed_ms), do: now_ms() - changed_ms

    if age_ms != nil and age_ms < state.settle_ms do
      Process.send_after(
        self(),
        {__MODULE__, :settled, recording.reference},
        state.settle_ms - age_ms
      )

      state
    else
      start_burst(state, changed_ms, age_ms)
    end
  end

  defp start_burst(%{recording: recording} = state, changed_ms, age_ms) do
    burst = %{
      phase: :burst,
      time: DateTime.utc_now(),
      started_ms: now_ms(),
      changed_ms: changed_ms,
      change_age_ms: age_ms,
      pairs: [],
      pair_count: 0,
      last_pair: nil,
      duration_reached: false,
      status_subscription: subscribe_to_status(state.status, recording.reference),
      status_available: false,
      snapshots: [],
      detections: []
    }

    Process.send_after(self(), {__MODULE__, :burst_elapsed, recording.reference}, state.burst_ms)
    %{state | recording: Map.merge(recording, burst)}
  end

  # From a process of its own: Status answers a subscription by asking the runner for its status.
  defp subscribe_to_status({subscribe, unsubscribe}, reference) do
    runner = self()

    spawn(fn ->
      monitor = Process.monitor(runner)
      subscribed = call_status(subscribe, runner)
      send(runner, {__MODULE__, :status_subscribed, reference, subscribed})

      receive do
        {__MODULE__, :unsubscribe} -> :ok
        {:DOWN, ^monitor, :process, _runner, _reason} -> :ok
      end

      call_status(unsubscribe, runner)
    end)
  end

  defp call_status(function, runner) do
    function.(runner)
    true
  catch
    :exit, _reason -> false
  end

  defp unsubscribe_from_status(%{status_subscription: subscription}),
    do: send(subscription, {__MODULE__, :unsubscribe})

  defp unsubscribe_from_status(_recording), do: :ok

  defp record_pair(%{recording: recording} = state, pair) do
    capture_ns = Pair.capture_ns(pair)

    recorded = %{
      capture_ns: capture_ns,
      interval_ms: interval_ms(recording.pairs, capture_ns),
      device_ms: pair.device_ms,
      sharpness: pair.sharpness,
      alignment: pair.alignment,
      metrics: pair.metrics,
      stage_ms: pair.stage_ms,
      frames:
        if(recording.pair_count < state.frames_kept, do: {pair.left_frame, pair.right_frame})
    }

    recording = %{
      recording
      | pairs: [recorded | recording.pairs],
        pair_count: recording.pair_count + 1,
        last_pair: pair
    }

    %{state | recording: recording}
  end

  defp interval_ms([], _capture_ns), do: nil

  defp interval_ms([previous | _pairs], capture_ns),
    do: (capture_ns - previous.capture_ns) / 1.0e6

  defp record_snapshot(%{recording: recording} = state, snapshot) do
    if now_ms() - recording.started_ms >= state.snapshot_delay_ms do
      snapshots = [snapshot | recording.snapshots]
      %{state | recording: %{recording | snapshots: snapshots, status_available: true}}
    else
      state
    end
  end

  defp finish_when_done(%{recording: recording} = state) do
    if recording.duration_reached and recording.pair_count >= state.burst_pairs,
      do: finish(state),
      else: state
  end

  # Encodes and answers off the runner, which keeps answering its status meanwhile.
  defp finish(%{recording: recording} = state) do
    Process.cancel_timer(recording.deadline)
    unsubscribe_from_status(recording)
    runner = self()
    burst = burst(state, recording)
    %{last_change: last_change, unit_state: unit_state, jpeg_codec: jpeg_codec} = state

    {:ok, _task} =
      Task.start(fn ->
        answer(recording.from, recording.reference, runner, fn ->
          build(burst, last_change, unit_state, jpeg_codec)
        end)
      end)

    %{state | recording: %{reference: recording.reference, phase: :answering}}
  end

  defp burst(state, recording) do
    %{
      time: recording.time,
      pairs: Enum.reverse(recording.pairs),
      last_pair: recording.last_pair,
      snapshots: Enum.reverse(recording.snapshots),
      detections: if(state.reads_detections, do: Enum.reverse(recording.detections)),
      changed_ms: recording.changed_ms,
      change_age_ms: recording.change_age_ms,
      status_available: recording.status_available
    }
  end

  defp answer(from, reference, runner, build) do
    VisionCore.Exporter.reply(from, export_result(build))
  after
    send(runner, {__MODULE__, :answered, reference})
  end

  defp export_result(build) do
    {filename, zip} = build.()
    {:file, filename, "application/zip", zip}
  rescue
    exception -> {:error, {:failed, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:failed, Exception.format_exit(reason)}}
  end

  defp build(burst, last_change, unit_state, jpeg_codec) do
    changes_during_burst = if last_change.() == burst.changed_ms, do: 0, else: 1
    check_last_pair!(burst.last_pair)

    unit_state.()
    |> Map.merge(burst)
    |> Map.put(:changes_during_burst, changes_during_burst)
    |> Map.put(:detections, burst.detections && Enum.map(burst.detections, &detection_entry/1))
    |> Map.put(:depth_coloured_jpeg, depth_jpeg(burst.last_pair, jpeg_codec))
    |> Export.build()
  end

  defp check_last_pair!(pair) do
    case Enum.filter(@last_pair_fields, &is_nil(Map.fetch!(pair, &1))) do
      [] ->
        :ok

      missing ->
        raise ArgumentError,
              "the last pair has no #{Enum.map_join(missing, ", ", &inspect/1)}, which the " <>
                "export needs: the stereo unit's stages do not provide it"
    end
  end

  defp detection_entry({capture_ns, size, detections}),
    do: %{
      "captureNs" => capture_ns,
      "detections" => Enum.map(detections, &detection_fields(&1, size))
    }

  # The fields of the API's detections event, as `VisionCore.Detection.Live` gives them.
  defp detection_fields(detection, {width, height}),
    do: %{
      "label" => detection.label,
      "score" => detection.score,
      "distanceM" => detection.z,
      "outline" => Enum.map(detection.outline, fn {x, y} -> [x / width, y / height] end)
    }

  defp depth_jpeg(pair, jpeg_codec) do
    case Preview.encode_depth(pair, @depth_range_m, jpeg_codec) do
      jpeg when is_binary(jpeg) -> jpeg
      {:error, _reason} -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp time_out(%{recording: recording} = state) do
    unsubscribe_from_status(recording)
    VisionCore.Exporter.reply(recording.from, {:error, {:timeout, timeout_message(state)}})
    %{state | recording: nil}
  end

  defp timeout_message(%{recording: %{phase: :settling}} = state),
    do:
      "0 of #{state.burst_pairs} pairs recorded by the #{state.deadline_ms} ms deadline, " <>
        "the unit still settling after a change"

  defp timeout_message(%{recording: recording} = state),
    do:
      "#{recording.pair_count} of #{state.burst_pairs} pairs recorded by the " <>
        "#{state.deadline_ms} ms deadline"

  defp last_change(pipeline) do
    [pipeline_change(pipeline), parameters_change()]
    |> Enum.filter(&is_integer/1)
    |> Enum.max(fn -> nil end)
  end

  defp pipeline_change(nil), do: nil

  defp pipeline_change(pipeline) do
    Pipeline.last_change(pipeline)
  catch
    :exit, _reason -> nil
  end

  defp parameters_change do
    Parameters.last_change()
  catch
    :exit, _reason -> nil
  end

  defp unit_state(config) do
    %{
      firmware: Firmware.current(),
      parameters: Parameters.groups(),
      configuration: VisionCore.settings(),
      calibration: calibration(config),
      hostname: hostname()
    }
  end

  defp calibration(config) do
    case StereoSupervisor.camera_options(config) do
      {:ok, cameras} ->
        %{left: read_calibration(cameras, :left), right: read_calibration(cameras, :right)}

      {:error, reason} ->
        raise ArgumentError, "cannot read the stereo unit's calibration: #{reason}"
    end
  end

  defp read_calibration(cameras, side) do
    case cameras[side][:calibration_path] do
      nil -> raise ArgumentError, "the stereo unit has no #{side} calibration path"
      path -> File.read!(path)
    end
  end

  defp hostname do
    {:ok, hostname} = :inet.gethostname()
    List.to_string(hostname)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
