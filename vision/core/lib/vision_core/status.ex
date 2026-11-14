defmodule VisionCore.Status do
  @moduledoc """
  The vision unit's health at a glance, for the dashboard: each camera's
  frame rate and exposure, the pair's sync, the NPU the detection and
  segmentation pipelines run on (`:npu`: the kind of the first one's,
  the detection pipelines' first, failed while any of their backends
  has, starting while one prepares its model and none has failed, its
  `:load_percent` and each pipeline's
  `:inference_ms`), the depth rate, each exporter's
  status (`VisionCore.Exporters.list/1`), the CPU's busy share
  (`OvcsVehicle.SystemLoad`) and the share of time the stereo pipeline
  spent in its compiled Nx or native segments (`Pair` `:device_ms`).
  Where they run on the GPU, that time
  includes uploading the frames and waiting for the results, so it is
  not the GPU's busy share. `:alignment` is the rectified images' row
  offset (`Pair` `:alignment`) and `:sharpness` each camera's sharpness
  (`Pair` `:sharpness`), and `:quality` the depth's quality
  (`VisionCore.Stereo.Stage.Quality`'s metrics: the share of matched
  pixels, the disparity's mean and spread, and its jitter), each averaged
  over the tick's pairs; `nil` without any. `:calibrated` is whether the
  stereo unit has both calibration files
  (`VisionCore.Stereo.Supervisor.calibrated?/1`), read at each snapshot;
  `nil` without a `:stereo` component, which has nothing to calibrate
  for depth.

  `:pair` judges the cameras together (`VisionCore.Stereo.PairCheck`):
  their timing, their rows, with the row correction the stage declaring
  `right_row_offset` applies, their focus and their brightness; each
  camera's `:issues` are those of the checks pointing at it. `:depth`
  judges how well the unit turns pairs into depth
  (`VisionCore.Stereo.DepthCheck`): the pairs it drops and how much of
  the last pair is nearer than it measures.

  Started after the components and the exporters in `VisionCore.Supervisor`.
  A listing of the exporters that misses its deadline reports those
  listed last as not answering.
  The sync is the stereo unit's measure (`VisionCore.Stereo.Pairer.sync/1`).
  Without a `:stereo` component the cameras and sync are reported absent
  and the depth rate is zero; the sync is absent too while neither camera
  runs, as once the stereo unit gave up.

  Each camera of its own (`VisionCore.Camera.Unit.cameras/1`) is reported
  beside the sides under its name, with its rate and the figures its
  driver's `live/1` gives, but no `:issues`, as the pair checks do not
  judge it.

  The NPU's load is the share of the last tick its pipelines spent
  inferring, summed over them and clamped to 100, and a pipeline's
  inference time the mean over the tick's frames, both from the
  accelerator times the backends report
  (`VisionCore.Detection.Backend.inference_times/1`, and
  `VisionCore.Segmentation.Backend`'s alike), which each tick
  reads and starts over, a snapshot asked between two not. Both are `nil`
  while no backend has reported a time.

  `:pipelines` holds each pipeline's times (`t:VisionCore.StageTimes.summary/0`)
  by its name, `:stereo` for the stereo pipeline: each step's mean time
  over the tick's pairs or frames, and their sum, the work one pair or
  frame takes, without the time it waits. The stereo pipeline's are its
  pairs' (`Pair` `:stage_ms`, less its `:total`, which counts the pair's
  waits): the stages a compiled segment runs as one function have one
  time, among `:segments`. A detection or segmentation pipeline's are
  those it hands over at each tick
  (`VisionCore.Detection.Pipeline.stage_times/1`,
  `VisionCore.Segmentation.Pipeline.stage_times/1`), a snapshot asked
  between two keeping the last tick's. A tick without a pair or a frame
  has no time, as has a pipeline that does not answer.

  Rates are counted over the last tick, one second by default (`:tick_ms`),
  and every subscriber receives `{:vision_status, snapshot}` each tick.
  """
  use GenServer

  alias VisionCore.{Exporter, Exporters, Outputs, Pipelines, StageTimes}
  alias VisionCore.Stereo.{AlignmentCorrection, DepthCheck, PairCheck, Pairer, Pipeline}
  alias VisionCore.Stereo.Supervisor, as: StereoSupervisor
  alias OvcsVehicle.SystemLoad
  alias VisionCore.Stereo.Pair
  alias VisionCore.Camera.{Frame, Unit}

  @default_tick_ms 1_000
  @call_timeout_ms 200
  @camera_metadata_keys [:exposure_time_us, :analogue_gain, :lens_position, :colour_temperature]
  @quality_metrics [:matched_percent, :mean_disparity_px, :spread_px, :jitter_px]

  @type camera :: %{required(:present) => boolean(), optional(atom()) => term()}
  @type exporter :: %{id: String.t(), name: String.t(), status: Exporter.status()}
  @type snapshot :: %{
          cameras: %{required(atom()) => camera()},
          sync: map(),
          npu:
            %{
              kind: String.t(),
              state: :starting | :running | :failed,
              load_percent: float() | nil,
              pipelines: %{required(atom()) => %{inference_ms: float() | nil}}
            }
            | nil,
          pipelines: %{required(atom()) => StageTimes.summary()},
          calibrated: boolean() | nil,
          depth_hz: float(),
          exporters: [exporter()],
          cpu_percent: float() | nil,
          stereo_segment_percent: float(),
          alignment: %{offset_rows: float(), band_offset_rows: [float() | nil]} | nil,
          pair: PairCheck.t(),
          depth: DepthCheck.t(),
          sharpness: %{left: float(), right: float()} | nil,
          quality:
            %{
              matched_percent: float(),
              mean_disparity_px: float(),
              spread_px: float(),
              jitter_px: float()
            }
            | nil
        }

  @doc """
  Starts the status server. Options: `:config`, the active
  `VisionCore.Config` (required), and `:tick_ms`.
  """
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The unit's status now, with the rates of the last tick."
  @spec snapshot() :: snapshot()
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc """
  Sends the caller `{:vision_status, snapshot}` now and every tick, until
  it exits or unsubscribes.
  """
  @spec subscribe() :: :ok
  def subscribe, do: subscribe(self())

  @doc """
  Sends `pid` `{:vision_status, snapshot}` now and every tick, until it
  exits or is unsubscribed. The call builds a snapshot, which asks each
  exporter's runner for its status, so a runner is subscribed from
  another process.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid), do: GenServer.call(__MODULE__, {:subscribe, pid})

  @doc "The row alignment of the last tick, without the snapshot's calls."
  @spec alignment() :: map() | nil
  def alignment, do: GenServer.call(__MODULE__, :alignment)

  @doc "Stops the caller's snapshots; one sent before may still arrive."
  @spec unsubscribe() :: :ok
  def unsubscribe, do: unsubscribe(self())

  @doc "Stops `pid`'s snapshots; one sent before may still arrive."
  @spec unsubscribe(pid()) :: :ok
  def unsubscribe(pid), do: GenServer.call(__MODULE__, {:unsubscribe, pid})

  @impl GenServer
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
    own_cameras = Unit.cameras(config)

    for {_output, key} <- StereoSupervisor.outputs(config) ++ Unit.outputs(config),
        do: :ok = Outputs.subscribe(key)

    own_names = Enum.map(own_cameras, fn {name, _driver, _server} -> name end)
    Process.send_after(self(), :tick, tick_ms)

    {:ok,
     %{
       tick_ms: tick_ms,
       config: config,
       cameras: StereoSupervisor.cameras(config),
       own_cameras: own_cameras,
       npu_backends: npu_backends(config),
       npu_times: nil,
       timed_pipelines: timed_pipelines(config),
       stereo_times: StageTimes.new(),
       pipelines: no_times(config),
       window_ms: 0,
       exporters: [],
       subscribers: %{},
       counts: zero_counts(own_names),
       device_ms: 0.0,
       cpu_times: SystemLoad.cpu_times(),
       cpu_percent: nil,
       stereo_segment_percent: 0.0,
       alignments: [],
       alignment: nil,
       sharpnesses: [],
       sharpness: nil,
       brightnesses: [],
       brightness: nil,
       last_pair: nil,
       near: nil,
       pair: nil,
       depth: nil,
       qualities: [],
       quality: nil,
       window_start_ms: now_ms(),
       rates_hz: Map.new(Map.keys(zero_counts(own_names)), &{&1, 0.0})
     }}
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state) do
    {snapshot, state} = build_snapshot(state)
    {:reply, snapshot, state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers = Map.put_new_lazy(state.subscribers, pid, fn -> Process.monitor(pid) end)
    {snapshot, state} = build_snapshot(state)
    send(pid, {:vision_status, snapshot})
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:alignment, _from, state), do: {:reply, state.alignment, state}

  def handle_call({:unsubscribe, pid}, _from, state) do
    {monitor_reference, subscribers} = Map.pop(state.subscribers, pid)
    if monitor_reference, do: Process.demonitor(monitor_reference, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  @impl GenServer
  def handle_cast({:stereo_pair, %Pair{} = pair}, state) do
    state = %{count(state, :depth) | device_ms: state.device_ms + pair.device_ms}
    state = %{state | stereo_times: add_stage_ms(state.stereo_times, pair.stage_ms)}

    {:noreply,
     %{
       state
       | alignments: prepend(pair.alignment, state.alignments),
         sharpnesses: prepend(pair.sharpness, state.sharpnesses),
         brightnesses: prepend(pair.brightness, state.brightnesses),
         last_pair: pair,
         qualities: prepend(quality(pair.metrics), state.qualities)
     }}
  end

  def handle_cast({:camera_frame, %Frame{label: label}}, state) do
    case Enum.find(Map.keys(state.counts), &(Atom.to_string(&1) == label)) do
      nil -> {:noreply, state}
      key -> {:noreply, count(state, key)}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {snapshot, state} = state |> close_window() |> build_snapshot(:tick)
    Enum.each(Map.keys(state.subscribers), &send(&1, {:vision_status, snapshot}))
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor_reference, :process, pid, _reason}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  defp zero_counts(own_names),
    do: Map.new([:left, :right, :depth | own_names], &{&1, 0})

  defp count(state, key), do: %{state | counts: Map.update!(state.counts, key, &(&1 + 1))}

  defp close_window(state) do
    now = now_ms()
    elapsed_ms = max(now - state.window_start_ms, 1)
    rates_hz = Map.new(state.counts, fn {key, count} -> {key, count * 1_000 / elapsed_ms} end)
    cpu_times = SystemLoad.cpu_times()

    %{
      state
      | rates_hz: rates_hz,
        counts: Map.new(state.counts, fn {key, _count} -> {key, 0} end),
        window_start_ms: now,
        window_ms: elapsed_ms,
        cpu_percent: SystemLoad.cpu_percent(state.cpu_times, cpu_times),
        cpu_times: cpu_times,
        stereo_segment_percent: min(100 * state.device_ms / elapsed_ms, 100.0),
        device_ms: 0.0,
        alignment: mean_alignment(state.alignments),
        alignments: [],
        sharpness: mean_sharpness(state.sharpnesses),
        sharpnesses: [],
        brightness: mean_sharpness(state.brightnesses),
        brightnesses: [],
        near: state.last_pair && DepthCheck.near(state.last_pair),
        last_pair: nil,
        quality: mean_quality(state.qualities),
        qualities: [],
        pipelines: Map.put(state.pipelines, :stereo, StageTimes.summary(state.stereo_times)),
        stereo_times: StageTimes.new()
    }
  end

  # A pair's `:total` counts its waits, which are no stage's work.
  defp add_stage_ms(times, stage_ms) do
    Enum.reduce(Map.delete(stage_ms, :total), times, fn {stage, duration_ms}, times ->
      StageTimes.add(times, stage, duration_ms)
    end)
  end

  defp prepend(nil, list), do: list
  defp prepend(value, list), do: [value | list]

  defp quality(metrics) do
    quality =
      for {name, value, _unit} <- metrics,
          name in @quality_metrics,
          into: %{},
          do: {name, value}

    if map_size(quality) == length(@quality_metrics), do: quality
  end

  defp mean_quality([]), do: nil

  defp mean_quality(qualities) do
    Map.new(@quality_metrics, fn key ->
      {key, Enum.sum(Enum.map(qualities, & &1[key])) / length(qualities)}
    end)
  end

  defp mean_sharpness([]), do: nil

  defp mean_sharpness(sharpnesses) do
    mean = fn side -> Enum.sum(Enum.map(sharpnesses, & &1[side])) / length(sharpnesses) end
    %{left: mean.(:left), right: mean.(:right)}
  end

  defp mean_alignment([]), do: nil

  defp mean_alignment(alignments) do
    %{
      offset_rows: alignments |> Enum.map(& &1.offset_rows) |> mean_of_measured(),
      band_offset_rows:
        alignments
        |> Enum.map(& &1.band_offset_rows)
        |> Enum.zip_with(& &1)
        |> Enum.map(&mean_of_measured/1)
    }
  end

  # `nil` stands for a band no pair measured.
  defp mean_of_measured(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      measured -> Enum.sum(measured) / length(measured)
    end
  end

  defp build_snapshot(state, moment \\ :between_ticks) do
    replies = state |> calls(moment) |> call_all_within_timeout()
    state = state |> npu_times(replies) |> pipeline_times(replies)
    cameras = %{left: camera(state, :left, replies), right: camera(state, :right, replies)}
    sync = sync(cameras, replies)
    state = listed(state, replies.exporters)

    pair =
      PairCheck.check(
        %{
          cameras: cameras,
          sync: sync,
          alignment: state.alignment,
          sharpness: state.sharpness,
          brightness: state.brightness,
          row_correction: Map.get(replies, :row_correction)
        },
        state.pair
      )

    depth =
      DepthCheck.check(
        %{
          cameras: cameras,
          depth_hz: state.rates_hz.depth,
          load_percent: state.stereo_segment_percent,
          near: state.near
        },
        state.depth
      )

    issues = PairCheck.camera_issues(pair)
    state = %{state | pair: pair, depth: depth}

    sides =
      Map.new(cameras, fn {side, camera} -> {side, Map.put(camera, :issues, issues[side])} end)

    snapshot = %{
      cameras: Map.merge(own_cameras(state, replies), sides),
      sync: sync,
      pair: pair,
      depth: depth,
      npu: npu(state, replies),
      pipelines: state.pipelines,
      calibrated: calibrated(state),
      depth_hz: state.rates_hz.depth,
      cpu_percent: state.cpu_percent,
      stereo_segment_percent: state.stereo_segment_percent,
      alignment: state.alignment,
      sharpness: state.sharpness,
      quality: state.quality,
      exporters: state.exporters
    }

    {snapshot, state}
  end

  defp listed(state, :late),
    do: %{
      state
      | exporters: Enum.map(state.exporters, &%{&1 | status: {:warning, "Not answering"}})
    }

  defp listed(state, exporters), do: %{state | exporters: exporters}

  # What the snapshot asks other processes, by key: the function and its answer when it fails.
  defp calls(state, moment) do
    %{exporters: {&exporters/0, :late}}
    |> Map.merge(npu_calls(state, moment))
    |> Map.merge(stage_times_calls(state, moment))
    |> Map.merge(stereo_calls(state))
    |> Map.merge(own_calls(state))
  end

  defp npu_calls(%{npu_backends: backends}, moment) do
    states =
      Map.new(backends, fn {_name, backend, server} ->
        {{:npu, server}, {fn -> backend_state(backend, server) end, :failed}}
      end)

    if moment == :tick, do: Map.merge(states, npu_times_calls(backends)), else: states
  end

  defp backend_state(backend, server) do
    cond do
      Code.ensure_loaded?(backend) and function_exported?(backend, :state, 1) ->
        backend.state(server)

      backend.available?(server) ->
        :running

      true ->
        :failed
    end
  end

  defp npu_times_calls(backends) do
    Map.new(backends, fn {_name, backend, server} ->
      {{:npu_times, server}, {fn -> backend.inference_times(server) end, nil}}
    end)
  end

  defp stage_times_calls(%{timed_pipelines: pipelines}, :tick) do
    Map.new(pipelines, fn {name, module, server} ->
      {{:stage_times, name}, {fn -> module.stage_times(server) end, nil}}
    end)
  end

  defp stage_times_calls(_state, :between_ticks), do: %{}

  # What the tick's replies make of the pipelines' times; other snapshots keep the last tick's.
  defp pipeline_times(state, replies) do
    taken =
      for {name, _module, _server} <- state.timed_pipelines,
          {:ok, times} <- [Map.fetch(replies, {:stage_times, name})],
          into: %{},
          do: {name, if(times, do: StageTimes.summary(times), else: StageTimes.none())}

    %{state | pipelines: Map.merge(state.pipelines, taken)}
  end

  # The detection and segmentation pipelines, each with the module that hands its times over.
  defp timed_pipelines(config) do
    detection =
      for {name, _backend, _server} <- VisionCore.Detection.Supervisor.pipelines(config),
          module = VisionCore.Detection.Pipeline,
          do: {name, module, Pipelines.server(module, name)}

    segmentation =
      for {name, _backend, _server} <- VisionCore.Segmentation.Supervisor.pipelines(config),
          module = VisionCore.Segmentation.Pipeline,
          do: {name, module, Pipelines.server(module, name)}

    detection ++ segmentation
  end

  defp no_times(config) do
    for {name, _module, _server} <- timed_pipelines(config),
        into: %{stereo: StageTimes.none()},
        do: {name, StageTimes.none()}
  end

  # Half the snapshot's deadline: the listing answers within it, a late exporter as not answering.
  defp exporters do
    for exporter <- Exporters.list(div(@call_timeout_ms, 2)),
        do: Map.take(exporter, [:id, :name, :status])
  end

  defp own_calls(%{own_cameras: own_cameras}) do
    for {name, driver, server} <- own_cameras,
        call <- camera_calls({:own, name}, {:running, name}, driver, server),
        into: %{},
        do: call
  end

  # What a camera's driver is asked, when it answers it: what it applied, whether its program runs.
  defp camera_calls(live_key, running_key, driver, server) do
    live =
      if function_exported?(driver, :live, 1),
        do: [{live_key, {fn -> live(driver, server) end, %{}}}],
        else: []

    running =
      if function_exported?(driver, :running?, 1),
        do: [{running_key, {fn -> driver.running?(server) end, true}}],
        else: []

    live ++ running
  end

  # A driver without its capture program, which it waits to start again, has no camera.
  defp present?(server, replies, running_key),
    do: GenServer.whereis(server) != nil and Map.get(replies, running_key, true)

  defp live(driver, server), do: Map.take(driver.live(server) || %{}, @camera_metadata_keys)

  defp own_cameras(state, replies) do
    Map.new(state.own_cameras, fn {name, _driver, server} ->
      if present?(server, replies, {:running, name}),
        do:
          {name,
           Map.merge(
             %{present: true, fps: state.rates_hz[name]},
             Map.get(replies, {:own, name}, %{})
           )},
        else: {name, %{present: false}}
    end)
  end

  defp stereo_calls(%{cameras: []}), do: %{}

  defp stereo_calls(%{cameras: cameras}) do
    sync = {fn -> Map.put(Pairer.sync(), :present, true) end, %{present: false}}
    row_correction = {&row_correction/0, nil}

    for {side, {driver, server}} <- Enum.zip([:left, :right], cameras),
        call <- camera_calls(side, {:running, side}, driver, server),
        into: %{sync: sync, row_correction: row_correction},
        do: call
  end

  # The rows the stage declaring `right_row_offset` moves the right image by, as the row correction sets them.
  defp row_correction do
    case AlignmentCorrection.offset_stage(Pipeline.stage_options(Pipeline)) do
      nil -> nil
      stage -> stage.values[:right_row_offset]
    end
  end

  defp camera(%{cameras: []}, _side, _replies), do: %{present: false}

  defp camera(%{cameras: [left, right]} = state, side, replies) do
    {_driver, server} = if side == :left, do: left, else: right

    if present?(server, replies, {:running, side}),
      do: Map.merge(%{present: true, fps: state.rates_hz[side]}, Map.get(replies, side, %{})),
      else: %{present: false}
  end

  # Cameras that are not running have no sync.
  defp sync(%{left: %{present: false}, right: %{present: false}}, _replies), do: %{present: false}
  defp sync(_cameras, replies), do: Map.get(replies, :sync, %{present: false})

  defp calibrated(%{cameras: []}), do: nil
  defp calibrated(state), do: StereoSupervisor.calibrated?(state.config)

  defp npu(%{npu_backends: []}, _replies), do: nil

  defp npu(%{npu_backends: [{_name, first, _server} | _others] = backends} = state, replies) do
    states = for {_name, _backend, server} <- backends, do: Map.fetch!(replies, {:npu, server})

    %{
      kind: first.npu_kind(),
      state: Enum.find([:failed, :starting], :running, &(&1 in states)),
      load_percent: state.npu_times && state.npu_times.load_percent,
      pipelines: pipelines(state)
    }
  end

  defp pipelines(%{npu_backends: backends, npu_times: nil}),
    do: Map.new(backends, fn {name, _backend, _server} -> {name, %{inference_ms: nil}} end)

  defp pipelines(%{npu_times: %{pipelines: pipelines}}), do: pipelines

  # The detection and segmentation units' backends that run on an accelerator, with their pipeline's name.
  defp npu_backends(config) do
    for {_name, backend, _server} = pipeline <-
          VisionCore.Detection.Supervisor.pipelines(config) ++
            VisionCore.Segmentation.Supervisor.pipelines(config),
        backend.npu_kind(),
        do: pipeline
  end

  # What the tick's replies make of the backends' inference times; other snapshots keep the last tick's.
  defp npu_times(%{npu_backends: []} = state, _replies), do: state

  defp npu_times(state, replies) do
    times =
      for {name, backend, server} <- state.npu_backends,
          do: {name, backend, Map.get(replies, {:npu_times, server}, :unasked)}

    if Enum.any?(times, fn {_name, _backend, reply} -> reply == :unasked end),
      do: state,
      else: %{state | npu_times: window_times(times, state.window_ms)}
  end

  # The load is the first accelerator's own: only the pipelines on its kind add up.
  defp window_times([{_name, first, _reply} | _others] = times, window_ms) do
    reported =
      for {_name, backend, %{sum_us: sum_us}} <- times,
          backend.npu_kind() == first.npu_kind(),
          do: sum_us

    %{
      load_percent:
        if(reported != [], do: min(100 * Enum.sum(reported) / 1_000 / window_ms, 100.0)),
      pipelines:
        Map.new(times, fn {name, _backend, reply} -> {name, %{inference_ms: mean_ms(reply)}} end)
    }
  end

  defp mean_ms(%{count: count, sum_us: sum_us}) when count > 0, do: sum_us / count / 1_000
  defp mean_ms(_none), do: nil

  defp now_ms, do: System.monotonic_time(:millisecond)

  # Callees stuck in their own work must not hold back the tick: all at once, late ones get their fallback.
  defp call_all_within_timeout(calls) do
    tasks =
      Map.new(calls, fn {key, {fun, fallback}} ->
        {key, {Task.async(fn -> call_or(fun, fallback) end), fallback}}
      end)

    replies =
      tasks
      |> Enum.map(fn {_key, {task, _fallback}} -> task end)
      |> Task.yield_many(@call_timeout_ms)
      |> Map.new(fn {task, reply} -> {task.ref, reply || Task.shutdown(task, :brutal_kill)} end)

    Map.new(tasks, fn {key, {task, fallback}} ->
      case replies[task.ref] do
        {:ok, reply} -> {key, reply}
        _late -> {key, fallback}
      end
    end)
  end

  defp call_or(fun, fallback) do
    fun.()
  catch
    _kind, _reason -> fallback
  end
end
