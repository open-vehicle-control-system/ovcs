defmodule VisionCore.Stereo.Pipeline do
  @moduledoc """
  Runs each submitted left/right pair through a list of
  `VisionCore.Stereo.Stage`s and publishes the finished
  `VisionCore.Stereo.Pair` as `{:stereo_pair, pair}` through
  `VisionCore.Outputs`, under `{:stereo_pair, name}`.

  The default stages, from `default_stages/1`, all written in Nx
  (`VisionCore.Stereo.NxStage`):

      Rectification   # camera frames → rectified grey images at the pipeline's size
      Sharpness       # each image's sharpness, to compare the cameras' focus
      Disparity       # disparity, libSGM's semi-global matching, ending with a 3×3 median
      SpeckleFilter   # drops small islands of disparity
      RowAlignment    # measures the rectified images' row offset
      TemporalFilter  # smoothing of the disparity over time
      Depth           # disparity → metric depth
      PointCloud      # depth → decimated point cloud
      Quality         # disparity statistics for the log line

  A stage list is checked at start: every field a stage requires must be
  provided by a stage before it, a tensor an Nx stage keeps on the device
  (`c:VisionCore.Stereo.NxStage.device_only/0`) by a stage before it in
  its segment, and the stages together must provide the disparity and
  depth its subscribers consume. A stage is named after the
  last segment of its module, underscored (`SpeckleFilter` is
  `:speckle_filter`): `stage_options/1` lists it, `set_options/3` and
  the timings address it by that name, so two stages of the same name
  are refused. Each stage is timed, and the timings are logged with the
  metrics stages report; each pair carries its own as `:stage_ms`.

  Each Nx stage runs on the first of the pipeline's `:backends`, the
  `VisionCore.Stereo.Segment`s, that accepts it, and consecutive stages
  one backend takes run as one segment, timed as one stage named after
  its members. By default, consecutive Nx stages are compiled at start
  into one `VisionCore.Stereo.NxSegment`, and so, through `nx_iree`, one
  module on the device. With `compute: :native`, consecutive stages
  that declare a native implementation
  (`c:VisionCore.Stereo.NxStage.native_kind/0`), every default one, run
  instead as one `VisionCore.Stereo.NativeSegment` in the `stereo_match`
  Port, a pair's one round trip, with each member's time logged under
  its name too; a stage no backend computes natively is compiled between
  the segments around it, which take their outputs as inputs, unless it
  would run on Nx's evaluator: without a compiler in `:defn_options`,
  the pipeline refuses to start. A stage not written in Nx runs on the
  BEAM, between the segments. The pipeline logs each run of stages at
  start, with where it computes.

  A stage computes as its `compute:` option says, `:nx` or `:native`,
  which the pipeline takes out of its options before `init/2`; else as
  its `c:VisionCore.Stereo.NxStage.compute/1` asks, as `Disparity`'s
  `:matcher` does; else as the pipeline's `:compute`. A `compute:` that
  the stage's own choice contradicts is refused at start, as is a choice
  no backend takes the stage for.

  Once the pipeline can take another pair, the process that submitted
  the last one receives `:stereo_pipeline_ready`;
  `VisionCore.Stereo.Pairer` submits the next pair then. Without a
  segment first, that is once the pair is done, whether it succeeded or
  not. With a segment first, it is once fewer pairs than the segment's
  `c:VisionCore.Stereo.Segment.depth/0` are at its device, and pairs
  are published in the order submitted. A compiled segment takes
  one pair at a time, so a pair is done once its device work is: the
  pair's outputs are collected and the later stages run while the next
  pair's device work does, and it is published then, or after
  `:flush_after_ms` if no pair follows. A native segment takes two, so
  the Port computes one while the other's frames and outputs go through
  the pipes: the next pair is taken once the earlier of the two is
  back, and that one is then collected, run through the later stages
  and published. A live setting of a native stage then
  applies from the second pair submitted after the change.

  A pair a segment refuses, such as one whose frames are of another
  size, never reaches the device, and a pair the device fails, as on an
  exception there or in the download of its outputs, is dropped too;
  each is logged. Ten pairs in a row that a device fails
  (`@max_failed_pairs`), with no pair it gets through between them,
  stop the pipeline, and so does a segment whose device does not answer
  within `:device_timeout_ms`, waiting for its reply or its download,
  for its supervisor to start it again. A device that refuses a segment
  itself, as the `stereo_match` Port refuses a configuration it cannot
  run, stops the pipeline at that pair, with the device's reason.

  ## Options

    * `:left_calibration_path`, `:right_calibration_path` (required) —
      `camera_calibration_parsers` YAMLs. The right camera's projection
      matrix `P_right[0,3] = -fx × T` encodes the baseline.
    * `:width`, `:height` (required) — the size the stages work at. The
      calibrations are scaled to it.
    * `:frame_width`, `:frame_height` (`:width`, `:height`) — the size
      of the submitted frames.
    * `:stages` (`default_stages/0`) — modules or `{module, opts}`, an
      Nx stage's `opts` with its `compute:`, if any.
    * `:compute` (`:nx`) — `:native` runs the stages that have a native
      implementation natively, through the `VisionCore.Stereo.Matcher`
      the `VisionCore.Stereo.NativeSegment` backend's `matcher:` names
      (`VisionCore.Stereo.Matcher` by default), which must be running;
      `:nx` compiles them.
    * `:backends` (`[NativeSegment, {NxSegment, defn_options: defn_options}]`)
      — the `VisionCore.Stereo.Segment`s to run Nx stages on, modules or
      `{module, opts}`, `opts` for its `c:VisionCore.Stereo.Segment.build/3`,
      in the order they are asked for each stage.
      `VisionCore.Stereo.Supervisor` passes the unit's.
    * `:defn_options` (`[]`, Nx's own defaults) — how the default
      backends' `VisionCore.Stereo.NxSegment` compiles; refused beside
      `:backends` (`check_backend_options!/1`).
    * `:flush_after_ms` (`100`) — how long a pair a compiled segment
      returned waits for the next one before it is finished alone; see
      above.
    * `:device_timeout_ms` (`10000`) — how long a pair may stay at a
      segment's device: past it the pipeline stops, for its supervisor to
      start it again, rather than wait on a device that no longer answers.
    * `:name` (`__MODULE__`) — the registered name, which the pairs are
      published under.
  """
  use GenServer
  require Logger

  @default_flush_after_ms 100
  @default_device_timeout_ms 10_000
  @reload_timeout_ms 30_000
  @max_failed_pairs 10

  alias VisionCore.Camera.Frame
  alias VisionCore.Outputs
  alias VisionCore.Parameters.Check
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.{NativeSegment, NxSegment, NxStage, Pair, Segment, Stage, StageTimer}

  @consumed [:left, :right, :disparity, :disparity_range, :disparity_bytes, :depth]

  @doc "Starts the pipeline; see the module doc for `opts`."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The default stages, with `overrides` merged into the options of the
  stage they name: `default_stages(disparity: [num_disparities: 128])`.
  Raises on an override that names none of them: a stage outside them,
  such as `VisionCore.Stereo.Stage.MedianFilter`, is one the composer
  inserts into the returned list.
  """
  @spec default_stages(keyword()) :: [{module(), keyword()}]
  def default_stages(overrides \\ []) do
    modules = [
      Stage.Rectification,
      Stage.Sharpness,
      Stage.Disparity,
      Stage.SpeckleFilter,
      Stage.RowAlignment,
      Stage.TemporalFilter,
      Stage.Depth,
      Stage.PointCloud,
      Stage.Quality
    ]

    names = Enum.map(modules, &stage_name/1)

    case Enum.reject(Keyword.keys(overrides), &(&1 in names)) do
      [] ->
        for module <- modules, do: {module, Keyword.get(overrides, stage_name(module), [])}

      unknown ->
        raise ArgumentError,
              "no default stage named #{Enum.map_join(unknown, ", ", &inspect/1)}; " <>
                "they are #{Enum.map_join(names, ", ", &inspect/1)}"
    end
  end

  @doc """
  Raises when `opts` give `:defn_options` beside `:backends`: they
  configure the default backends' `VisionCore.Stereo.NxSegment`, which
  takes them among its own options in `:backends`. A `nil` option is
  not given.
  """
  @spec check_backend_options!(keyword()) :: :ok
  def check_backend_options!(opts) do
    if Keyword.get(opts, :backends) != nil and Keyword.get(opts, :defn_options) != nil,
      do:
        raise(
          ArgumentError,
          ":defn_options sets the default backends' NxSegment: " <>
            "with :backends, give it among NxSegment's options"
        )

    :ok
  end

  @doc "Queues one left/right frame pair; the caller receives `:stereo_pipeline_ready` once it is done."
  def submit(server, %Frame{} = left, %Frame{} = right),
    do: GenServer.cast(server, {:submit, left, right, self()})

  @typedoc "A stage's settings, as `stage_options/1` lists them."
  @type stage_options :: %{
          stage: atom(),
          module: module(),
          summary: String.t(),
          explanation: String.t() | nil,
          specs: [{atom(), Stage.option_spec()}],
          values: %{atom() => term()}
        }

  @doc """
  Every stage in pipeline order, the members of a compiled segment
  among them: its name, module, summary, explanation, settings (`applies`
  filled in) and their values. A setting that takes effect only with
  other settings' values (`:when`) is left out while they differ.
  """
  @spec stage_options(GenServer.server()) :: [stage_options()]
  def stage_options(server), do: GenServer.call(server, :stage_options)

  @doc """
  Changes live settings of `stage` from the next pair on. Returns the
  stage's values now in force, or why the request was refused, in
  which case none changed.
  """
  @spec set_options(GenServer.server(), atom(), keyword()) ::
          {:ok, %{atom() => term()}} | {:error, String.t()}
  def set_options(server, stage, options),
    do: GenServer.call(server, {:set_options, stage, options})

  @typedoc "A segment the pipeline runs: its name, its backend and its state."
  @type segment :: %{name: atom(), module: module(), state: Segment.t()}

  @doc "The segments the pipeline runs, in pipeline order."
  @spec segments(GenServer.server()) :: [segment()]
  def segments(server), do: GenServer.call(server, :segments)

  @doc """
  Reloads the calibration from the YAMLs on disk and rebuilds every
  stage with its settings in force, so the next pair reflects the new
  geometry. `paths` (`:left_calibration_path`, `:right_calibration_path`)
  replaces the YAMLs to read, for this and later reloads, once they load.
  The call waits #{div(@reload_timeout_ms, 1_000)} s for the stages to be rebuilt, then exits.
  """
  def reload_calibration(server, paths \\ []),
    do: GenServer.call(server, {:reload_calibration, paths}, @reload_timeout_ms)

  @doc """
  The monotonic time, in milliseconds, of the pipeline's start, of its
  latest `set_options/3` that changed a setting's value, or of its latest
  `reload_calibration/2` that succeeded, whichever is later: the last time
  what the stages compute changed.
  """
  @spec last_change(GenServer.server()) :: integer()
  def last_change(server), do: GenServer.call(server, :last_change)

  @impl GenServer
  def init(opts) do
    context = context(opts)
    compute = Keyword.get(opts, :compute, :nx)

    if compute not in [:nx, :native],
      do: raise(ArgumentError, "compute is :nx or :native, got #{inspect(compute)}")

    backends = backends(opts)

    stages =
      opts
      |> Keyword.get_lazy(:stages, &default_stages/0)
      |> Enum.map(&normalise_stage/1)

    check_stages!(stages)
    check_names!(stages)
    check_order!(stages)
    check_live_settings!(stages)

    stages =
      stages
      |> Enum.map(&initialise_stage!(&1, context))
      |> group_stages(backends, compute, context)

    log_ready(context, stages)

    {:ok,
     %{
       opts: opts,
       context: context,
       stages: stages,
       output: {:stereo_pair, Keyword.get(opts, :name, __MODULE__)},
       timer: StageTimer.new(window: 30, label: "pipeline"),
       last_change_ms: System.monotonic_time(:millisecond),
       last_start_ns: nil,
       in_flight: :queue.new(),
       held: nil,
       flush: nil,
       queued: nil,
       last_reply_ns: nil,
       collected_ns: nil,
       waiting_submitter: nil,
       failed_pairs: 0,
       stop: nil,
       flush_after_ms: Keyword.get(opts, :flush_after_ms, @default_flush_after_ms),
       device_timeout_ms: Keyword.get(opts, :device_timeout_ms, @default_device_timeout_ms)
     }}
  end

  @impl GenServer
  def handle_call(:stage_options, _from, state) do
    stages =
      for stage <- state.stages,
          member <- members(stage),
          do: Map.put(describe(member), :compute, compute(stage))

    {:reply, stages, state}
  end

  def handle_call(:segments, _from, state) do
    segments =
      for %{kind: :segment} = stage <- state.stages, do: Map.take(stage, [:name, :module, :state])

    {:reply, segments, state}
  end

  def handle_call(:last_change, _from, state), do: {:reply, state.last_change_ms, state}

  def handle_call({:set_options, name, options}, _from, state) do
    with {:ok, location, stage} <- find_stage(state.stages, name),
         {:ok, stage_state} <- apply_options(stage, options) do
      stages = put_stage_state(state.stages, location, stage_state)

      last_change_ms =
        if changed?(stage, stage_state),
          do: System.monotonic_time(:millisecond),
          else: state.last_change_ms

      state = %{state | stages: stages, last_change_ms: last_change_ms}
      {:reply, {:ok, values(%{stage | state: stage_state})}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reload_calibration, paths}, _from, state) do
    opts = Keyword.merge(state.opts, paths)
    context = context(opts)
    stages = Enum.map(state.stages, &reinitialise_stage!(&1, context))

    Logger.info(
      "#{__MODULE__} reloaded calibration " <>
        "(fx=#{Float.round(context.focal_length_px, 2)} px, " <>
        "baseline=#{Float.round(context.baseline_m, 4)} m)"
    )

    {:reply, :ok,
     %{
       state
       | opts: opts,
         context: context,
         stages: stages,
         last_change_ms: System.monotonic_time(:millisecond)
     }}
  rescue
    error ->
      Logger.warning("#{__MODULE__}: reload_calibration failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @impl GenServer
  def handle_cast({:submit, %Frame{} = left, %Frame{} = right, submitter}, state) do
    start_ns = System.monotonic_time(:nanosecond)
    pair = %Pair{left_frame: left, right_frame: right, geometry: state.context}

    case state.stages do
      [%{kind: :segment, module: module} = first | _rest] ->
        # A pair submitted before the pipeline was ready is sent once the oldest one is back.
        if :queue.len(state.in_flight) < module.depth(),
          do: noreply(send_pair(pair, first, start_ns, submitter, state)),
          else: {:noreply, %{state | queued: {pair, start_ns, submitter}}}

      stages ->
        {outcome, stages, timer} = run_stages(pair, stages, state.timer, state.device_timeout_ms)
        state = finish_pair(%{state | stages: stages, timer: timer}, outcome, start_ns)
        if state.stop == nil, do: send(submitter, :stereo_pipeline_ready)
        noreply(state)
    end
  end

  @impl GenServer
  def handle_info({:flush, ref}, %{flush: ref} = state), do: noreply(finish_held(state))

  def handle_info({:device_deadline, deadline}, %{stages: [first | _rest]} = state) do
    if Enum.any?(:queue.to_list(state.in_flight), &(&1.deadline == deadline)),
      do: state |> device_timeout(first.name) |> noreply(),
      else: {:noreply, state}
  end

  def handle_info(message, state) do
    with {:value, sent} <- :queue.peek(state.in_flight),
         [first | _rest] = state.stages,
         response when response != :no_reply <-
           first.module.response(message, sent.ticket, sent.segment) do
      noreply(receive_reply(response, sent, state))
    else
      _other -> {:noreply, state}
    end
  end

  # A device that stopped answering, or keeps failing, stops the pipeline for a restart.
  defp noreply(%{stop: nil} = state), do: {:noreply, state}
  defp noreply(%{stop: reason} = state), do: {:stop, reason, state}

  defp device_timeout(state, name) do
    Logger.error(
      "#{__MODULE__}: no answer from #{name}'s device in #{state.device_timeout_ms} ms"
    )

    %{state | stop: {:device_timeout, state.device_timeout_ms}}
  end

  defp device_refused(state, name, reason) do
    Logger.error("#{__MODULE__}: #{name}'s device refuses it: #{inspect(reason)}")
    %{state | stop: {:device_refused, name, reason}}
  end

  defp device_failed(state, name, reason) do
    failed_pairs = state.failed_pairs + 1

    if failed_pairs >= @max_failed_pairs do
      Logger.error("#{__MODULE__}: #{name}'s device failed #{failed_pairs} pairs in a row")
      %{state | failed_pairs: failed_pairs, stop: {:device_failing, name, reason}}
    else
      %{state | failed_pairs: failed_pairs}
    end
  end

  defp send_pair(pair, %{module: module} = first, start_ns, submitter, state) do
    case module.send_request(pair, first.state) do
      {:ok, ticket} ->
        deadline = make_ref()
        timer = Process.send_after(self(), {:device_deadline, deadline}, state.device_timeout_ms)

        sent = %{
          ticket: ticket,
          pair: pair,
          segment: first.state,
          start_ns: start_ns,
          sent_ns: System.monotonic_time(:nanosecond),
          deadline: deadline,
          deadline_timer: timer
        }

        %{state | in_flight: :queue.in(sent, state.in_flight), waiting_submitter: submitter}
        |> finish_held()
        |> ready()

      {:error, reason} ->
        send(submitter, :stereo_pipeline_ready)
        finish_pair(state, {:error, module, reason}, start_ns)
    end
  end

  # The segment's device time runs from when the device could start on the pair.
  defp receive_reply(response, sent, %{stages: [first | rest]} = state) do
    Process.cancel_timer(sent.deadline_timer)
    state = %{state | in_flight: :queue.drop(state.in_flight)}

    state =
      case response do
        {:ok, outputs, segment, done_ns} ->
          device_ns = done_ns - max(sent.sent_ns, state.last_reply_ns || sent.sent_ns)

          replied =
            Map.merge(sent, %{
              segment: segment,
              outputs: outputs,
              device_ns: device_ns,
              done_ns: done_ns
            })

          # A live setting or a reload may have replaced the segment the pair was sent with.
          first = %{first | state: first.module.merge_carry(first.state, segment)}
          state = %{state | stages: [first | rest], last_reply_ns: done_ns}

          # One pair at a time at the device: the pair is finished while the next one's device
          # work runs, or after :flush_after_ms if none follows.
          if first.module.depth() == 1 do
            ref = make_ref()
            Process.send_after(self(), {:flush, ref}, state.flush_after_ms)
            state = finish_held(state)
            %{state | held: replied, flush: ref}
          else
            finish_replied(state, replied)
          end

        {:error, reason} ->
          state = %{state | last_reply_ns: System.monotonic_time(:nanosecond)}
          finish_pair(state, {:device_error, first.module, first.name, reason}, sent.start_ns)

        {:stop, reason} ->
          finish_pair(state, {:device_refused, first.name, reason}, sent.start_ns)
      end

    state |> send_queued() |> ready()
  end

  # Once stopping, the pipeline sends no pair and tells no submitter it is ready.
  defp send_queued(%{stop: stop} = state) when stop != nil, do: state
  defp send_queued(%{queued: nil} = state), do: state

  defp send_queued(%{queued: {pair, start_ns, submitter}, stages: [first | _rest]} = state),
    do: send_pair(pair, first, start_ns, submitter, %{state | queued: nil})

  defp ready(%{stop: stop} = state) when stop != nil, do: state
  defp ready(%{waiting_submitter: nil} = state), do: state

  defp ready(%{stages: [%{kind: :segment, module: module} | _rest]} = state) do
    if :queue.len(state.in_flight) < module.depth() do
      send(state.waiting_submitter, :stereo_pipeline_ready)
      %{state | waiting_submitter: nil}
    else
      state
    end
  end

  defp finish_held(%{held: nil} = state), do: state

  defp finish_held(%{held: held} = state),
    do: finish_replied(%{state | held: nil, flush: nil}, held)

  defp finish_replied(%{stages: [%{module: module} = first | _rest]} = state, replied) do
    {collect_ns, collected} =
      timed(fn ->
        module.collect(replied.pair, replied.outputs, replied.segment, state.device_timeout_ms)
      end)

    case collected do
      {:ok, pair} ->
        finish_collected(state, replied, pair, collect_ns)

      {:error, reason} ->
        finish_pair(state, {:device_error, module, first.name, reason}, replied.start_ns)

      :timeout ->
        finish_pair(state, {:device_timeout, first.name}, replied.start_ns)
    end
  end

  defp finish_collected(
         %{stages: [%{module: module} = first | rest]} = state,
         replied,
         pair,
         collect_ns
       ) do
    collected_ns = System.monotonic_time(:nanosecond)
    pair = %{pair | device_ms: replied.device_ns / 1_000_000}
    segment_ns = segment_ns(replied, collect_ns, state.collected_ns)
    timings = [{first.name, segment_ns} | module.member_times(replied.segment)]
    pair = put_stage_ms(pair, timings)
    timer = record_timings(state.timer, timings)

    {outcome, rest, timer} = run_stages(pair, rest, timer, state.device_timeout_ms)

    finish_pair(
      %{state | stages: [first | rest], timer: timer, collected_ns: collected_ns},
      outcome,
      replied.start_ns
    )
  end

  # The previous pair's download runs during this pair's device work: that time counts once.
  defp segment_ns(replied, collect_ns, nil), do: replied.device_ns + collect_ns

  defp segment_ns(replied, collect_ns, previous_collected_ns) do
    device_start_ns = max(replied.done_ns - replied.device_ns, previous_collected_ns)
    max(replied.done_ns - device_start_ns, 0) + collect_ns
  end

  defp finish_pair(state, outcome, start_ns) do
    total_ns = System.monotonic_time(:nanosecond) - start_ns

    state =
      case outcome do
        {:ok, %Pair{} = pair} ->
          Outputs.publish(state.output, {:stereo_pair, put_stage_ms(pair, total: total_ns)})
          %{state | failed_pairs: 0}

        {:error, module, reason} ->
          Logger.warning("#{__MODULE__}: #{inspect(module)} failed: #{inspect(reason)}")
          state

        {:device_error, module, name, reason} ->
          Logger.warning("#{__MODULE__}: #{inspect(module)} failed: #{inspect(reason)}")
          device_failed(state, name, reason)

        {:device_timeout, name} ->
          device_timeout(state, name)

        {:device_refused, name, reason} ->
          device_refused(state, name, reason)
      end

    timer =
      state.timer
      |> StageTimer.record(:total, total_ns)
      |> StageTimer.record(:wall, elapsed_since(state.last_start_ns, start_ns))
      |> StageTimer.tick()

    %{state | timer: timer, last_start_ns: start_ns}
  end

  defp run_stages(pair, stages, timer, timeout_ms) do
    {outcome, done, timer} =
      Enum.reduce(stages, {{:ok, pair}, [], timer}, fn
        stage, {{:ok, pair}, done, timer} ->
          {elapsed_ns, result} = timed(fn -> run_stage(pair, stage, timeout_ms) end)
          {outcome, stage, member_times} = stage_outcome(stage, result, elapsed_ns)
          timings = [{stage.name, elapsed_ns} | member_times]
          {put_outcome_stage_ms(outcome, timings), [stage | done], record_timings(timer, timings)}

        stage, {error, done, timer} ->
          {error, [stage | done], timer}
      end)

    {outcome, Enum.reverse(done), record_metrics(timer, outcome)}
  end

  # A segment after the first runs at once, each wait on its device up to the device timeout.
  defp run_stage(pair, %{kind: :segment, module: module, state: segment}, timeout_ms),
    do: Segment.run(module, pair, segment, timeout_ms)

  defp run_stage(pair, stage, _timeout_ms), do: stage.module.run(pair, stage.state)

  # The outcome, the stage to keep and the times of the members of a segment.
  defp stage_outcome(%{kind: :segment} = stage, {:ok, pair, segment}, elapsed_ns) do
    pair = %{pair | device_ms: pair.device_ms + elapsed_ns / 1_000_000}
    {{:ok, pair}, %{stage | state: segment}, stage.module.member_times(segment)}
  end

  defp stage_outcome(stage, {:ok, pair, stage_state}, _elapsed_ns),
    do: {{:ok, pair}, %{stage | state: stage_state}, []}

  defp stage_outcome(stage, {:error, reason, stage_state}, _elapsed_ns),
    do: {{:error, stage.module, reason}, %{stage | state: stage_state}, []}

  defp stage_outcome(stage, {:refused, reason}, _elapsed_ns),
    do: {{:error, stage.module, reason}, stage, []}

  defp stage_outcome(stage, {:error, reason}, _elapsed_ns),
    do: {{:device_error, stage.module, stage.name, reason}, stage, []}

  defp stage_outcome(stage, :timeout, _elapsed_ns),
    do: {{:device_timeout, stage.name}, stage, []}

  defp stage_outcome(stage, {:stop, reason}, _elapsed_ns),
    do: {{:device_refused, stage.name, reason}, stage, []}

  defp record_timings(timer, timings) do
    Enum.reduce(timings, timer, fn {name, duration_ns}, timer ->
      StageTimer.record(timer, name, duration_ns)
    end)
  end

  # A member's time replaces the one of its segment when that has one stage and its name.
  defp put_stage_ms(pair, timings) do
    stage_ms = Map.new(timings, fn {name, duration_ns} -> {name, duration_ns / 1_000_000} end)
    %{pair | stage_ms: Map.merge(pair.stage_ms, stage_ms)}
  end

  defp put_outcome_stage_ms({:ok, pair}, timings), do: {:ok, put_stage_ms(pair, timings)}
  defp put_outcome_stage_ms(outcome, _timings), do: outcome

  defp record_metrics(timer, {:ok, %Pair{metrics: metrics}}) do
    Enum.reduce(metrics, timer, fn {name, value, unit}, timer ->
      StageTimer.record_scalar(timer, name, value, unit)
    end)
  end

  defp record_metrics(timer, _error), do: timer

  defp timed(fun) do
    start_ns = System.monotonic_time(:nanosecond)
    returned = fun.()
    {System.monotonic_time(:nanosecond) - start_ns, returned}
  end

  defp elapsed_since(nil, _now_ns), do: 0
  defp elapsed_since(previous_ns, now_ns), do: now_ns - previous_ns

  # `compute:` is the pipeline's own option, not the stage's.
  defp normalise_stage({module, opts}) when is_atom(module) and is_list(opts) do
    {compute, opts} = Keyword.pop(opts, :compute)

    if compute not in [nil, :nx, :native],
      do:
        raise(
          ArgumentError,
          "#{inspect(module)}: compute is :nx or :native, got #{inspect(compute)}"
        )

    %{kind: :stage, module: module, opts: opts, name: stage_name(module), compute: compute}
  end

  defp normalise_stage(module) when is_atom(module), do: normalise_stage({module, []})

  @doc """
  The name the stage `module` goes by in the pipeline, its parameters'
  ids and `stage_options/1`: its last segment, underscored.
  """
  @spec stage_name(module()) :: atom()
  def stage_name(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

  defp backends(opts) do
    check_backend_options!(opts)

    case Keyword.get(opts, :backends) do
      nil ->
        [{NativeSegment, []}, {NxSegment, defn_options: Keyword.get(opts, :defn_options) || []}]

      backends ->
        Enum.map(backends, &normalise_backend/1)
    end
  end

  defp normalise_backend({module, opts}) when is_atom(module) and is_list(opts) do
    if Stage.implements?(module, Segment),
      do: {module, opts},
      else: raise(ArgumentError, "#{inspect(module)} is not a VisionCore.Stereo.Segment")
  end

  defp normalise_backend(module) when is_atom(module), do: normalise_backend({module, []})

  defp check_stages!(stages) do
    Enum.each(stages, fn stage ->
      Code.ensure_loaded!(stage.module)
      nx_stage? = NxStage.nx_stage?(stage.module)

      cond do
        not (nx_stage? or Stage.implements?(stage.module, Stage)) ->
          raise ArgumentError,
                "#{inspect(stage.module)} implements neither VisionCore.Stereo.Stage " <>
                  "nor VisionCore.Stereo.NxStage"

        stage.compute != nil and not nx_stage? ->
          raise ArgumentError,
                "#{inspect(stage.module)} is not an Nx stage: " <>
                  "compute: #{inspect(stage.compute)} does not apply to it"

        true ->
          :ok
      end
    end)
  end

  defp check_names!(stages) do
    stages
    |> Enum.group_by(& &1.name, & &1.module)
    |> Enum.each(fn
      {_name, [_module]} ->
        :ok

      {_name, [module, module | _]} ->
        raise ArgumentError, "#{inspect(module)} is listed twice among the stages"

      {name, [first, second | _]} ->
        raise ArgumentError,
              "#{inspect(first)} and #{inspect(second)} are both named #{inspect(name)}, " <>
                "after the last segment of their modules"
    end)
  end

  defp check_order!(stages) do
    provided =
      Enum.reduce(stages, MapSet.new([:left_frame, :right_frame]), fn stage, provided ->
        case Enum.reject(stage.module.requires(), &MapSet.member?(provided, &1)) do
          [] ->
            MapSet.union(provided, MapSet.new(stage.module.provides()))

          missing ->
            raise ArgumentError,
                  "#{inspect(stage.module)} needs #{inspect(missing)}, " <>
                    "which no stage before it provides"
        end
      end)

    case Enum.reject(@consumed, &MapSet.member?(provided, &1)) do
      [] -> :ok
      missing -> raise ArgumentError, "no stereo stage provides #{inspect(missing)}"
    end
  end

  defp check_live_settings!(stages) do
    stages
    |> Enum.reject(&function_exported?(&1.module, :set_option, 3))
    |> Enum.each(fn stage ->
      case for({key, %{applies: :live}} <- option_specs(stage.module), do: key) do
        [] ->
          :ok

        live ->
          raise ArgumentError,
                "#{inspect(stage.module)} declares the live settings #{inspect(live)} " <>
                  "but no set_option/3"
      end
    end)
  end

  # Each run of consecutive stages one backend takes becomes one segment stage.
  defp group_stages(stages, backends, compute, context) do
    runs =
      stages
      |> Enum.map(&placement(&1, backends, compute))
      |> Enum.chunk_by(&elem(&1, 0))

    check_device_only!(runs)

    Enum.flat_map(runs, fn
      [{:cpu, _stage, _fallback?} | _] = run ->
        Enum.map(run, &elem(&1, 1))

      [{{backend, backend_opts}, _stage, _fallback?} | _] = run ->
        segment = segment_stage!(Enum.map(run, &elem(&1, 1)), backend, backend_opts, context)
        check_fallbacks!(segment, for({_backend, stage, true} <- run, do: stage.module))
        [segment]
    end)
  end

  # An Nx stage computes as it asks, else as :compute says, and under :native falls back to :nx.
  defp placement(stage, backends, compute) do
    cond do
      not NxStage.nx_stage?(stage.module) ->
        {:cpu, stage, false}

      asked = own_compute!(stage) ->
        {backend!(backends, stage, asked), stage, false}

      backend = compute == :native && backend(backends, stage, :native) ->
        {backend, stage, false}

      true ->
        {backend!(backends, stage, :nx), stage, compute == :native}
    end
  end

  # Before the segments are built, which would refuse such a stage as reading from a CPU stage.
  defp check_device_only!(runs) do
    stages =
      for {run, index} <- Enum.with_index(runs),
          {_on, stage, _fallback?} <- run,
          do: {stage, index}

    Enum.reduce(stages, %{}, fn {stage, index}, kept ->
      check_kept!(stage, kept, index)
      kept_after(stage, kept, index)
    end)
  end

  defp kept_after(stage, kept, index) do
    device_only = NxStage.device_only(stage.module)

    Enum.reduce(stage.module.provides(), kept, fn field, kept ->
      if field in device_only,
        do: Map.put(kept, field, {stage.module, index}),
        else: Map.delete(kept, field)
    end)
  end

  defp check_kept!(stage, kept, index) do
    for field <- stage.module.requires(),
        {keeper, keeper_index} <- [kept[field]],
        keeper_index != index do
      raise ArgumentError,
            "#{inspect(stage.module)} needs #{inspect(field)}, which #{inspect(keeper)} keeps " <>
              "on the device for the stages after it in its segment"
    end
  end

  defp backend(backends, stage, compute),
    do:
      Enum.find(backends, fn {backend, _opts} ->
        backend.accepts?(stage.module, stage.state, compute)
      end)

  defp backend!(backends, stage, compute) do
    backend(backends, stage, compute) ||
      raise ArgumentError,
            "no backend takes #{inspect(stage.module)} to compute #{inspect(compute)}"
  end

  # The stage's own choice: its compute: pin, else its compute/1; nil leaves it to the pipeline.
  defp own_compute!(stage) do
    case {stage.compute, NxStage.compute(stage.module, stage.state)} do
      {nil, own} ->
        own

      {pinned, own} when own in [nil, pinned] ->
        pinned

      {pinned, own} ->
        raise ArgumentError,
              "#{inspect(stage.module)} is pinned to compute: #{inspect(pinned)}, " <>
                "but its own options ask for #{inspect(own)}"
    end
  end

  # Refused on Nx's evaluator, far too slow for a stage asked to compute natively.
  defp check_fallbacks!(_segment, []), do: :ok

  defp check_fallbacks!(segment, modules) do
    if compute(segment).backend == :evaluator,
      do:
        raise(
          ArgumentError,
          "no backend computes #{Enum.map_join(modules, ", ", &inspect/1)} natively, and " <>
            "without a compiler in :defn_options it would run on Nx's evaluator"
        )
  end

  defp segment_stage!(members, backend, backend_opts, context) do
    name = members |> Enum.map_join("+", & &1.name) |> String.to_atom()

    case backend.build(members, context, backend_opts) do
      {:ok, segment} -> %{kind: :segment, module: backend, name: name, state: segment}
      {:error, reason} -> raise ArgumentError, "#{name} cannot start: #{reason}"
    end
  end

  defp initialise_stage!(stage, context) do
    case stage.module.init(stage.opts, context) do
      {:ok, stage_state} -> Map.put(stage, :state, stage_state)
      {:error, reason} -> raise ArgumentError, "#{inspect(stage.module)} cannot start: #{reason}"
    end
  end

  defp reinitialise_stage!(%{kind: :segment, module: module, state: segment} = stage, context) do
    members = Enum.map(segment.members, &reinitialise_stage!(&1, context))
    %{stage | state: module.reload(segment, members, context)}
  end

  # Settings changed while running survive the rebuild.
  defp reinitialise_stage!(stage, context) do
    opts = Keyword.merge(stage.opts, Map.to_list(values(stage)))
    initialise_stage!(%{stage | opts: opts}, context)
  end

  defp members(%{kind: :segment, state: segment}), do: segment.members
  defp members(stage), do: [stage]

  defp compute(%{kind: :segment, module: module, state: segment}), do: module.compute(segment)

  defp compute(_stage), do: %{runs_on: :cpu, implementation: :elixir, backend: nil}

  defp describe(stage) do
    values = values(stage)

    {specs, idle} =
      Enum.split_with(option_specs(stage.module), fn {_key, spec} ->
        Enum.all?(Map.get(spec, :when, []), fn {key, value} -> values[key] == value end)
      end)

    %{
      stage: stage.name,
      module: stage.module,
      summary: summary(stage.module),
      explanation: explanation(stage.module),
      specs: specs,
      values: Map.drop(values, Keyword.keys(idle))
    }
  end

  defp summary(module) do
    if function_exported?(module, :summary, 0), do: module.summary(), else: ""
  end

  defp explanation(module) do
    if function_exported?(module, :explanation, 0), do: module.explanation()
  end

  defp option_specs(module) do
    if function_exported?(module, :option_specs, 0),
      do:
        Enum.map(module.option_specs(), fn {key, spec} ->
          {key, Map.put_new(spec, :applies, :live)}
        end),
      else: []
  end

  defp values(stage) do
    if function_exported?(stage.module, :options, 1),
      do: stage.module.options(stage.state),
      else: %{}
  end

  # By the stage's settings, or by its state when it does not report them.
  defp changed?(stage, stage_state) do
    if function_exported?(stage.module, :options, 1),
      do: values(stage) != values(%{stage | state: stage_state}),
      else: stage.state != stage_state
  end

  # `{index, nil}` for a stage, `{index, member_index}` for a member of a segment.
  defp find_stage(stages, name) do
    stages
    |> Enum.with_index()
    |> Enum.find_value({:error, "no stereo stage #{inspect(name)}"}, fn
      {%{kind: :segment, state: segment}, index} ->
        case Enum.find_index(segment.members, &(&1.name == name)) do
          nil -> nil
          member -> {:ok, {index, member}, Enum.at(segment.members, member)}
        end

      {stage, index} ->
        if stage.name == name, do: {:ok, {index, nil}, stage}
    end)
  end

  defp apply_options(stage, options) do
    specs = option_specs(stage.module)

    Enum.reduce_while(options, {:ok, stage.state}, fn {key, value}, {:ok, stage_state} ->
      case apply_option(stage, specs, stage_state, key, value) do
        {:ok, stage_state} -> {:cont, {:ok, stage_state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # A key the stage cannot change is refused before the stage sees it, under the stage's name.
  defp apply_option(stage, specs, stage_state, key, value) do
    case Check.live_setting(specs, key) do
      :ok -> stage.module.set_option(stage_state, key, value)
      {:error, reason} -> {:error, "#{stage.name}.#{reason}"}
    end
  end

  defp put_stage_state(stages, {index, nil}, stage_state),
    do: List.update_at(stages, index, &%{&1 | state: stage_state})

  defp put_stage_state(stages, {index, member}, stage_state) do
    List.update_at(stages, index, fn %{module: module} = segment_stage ->
      %{segment_stage | state: module.put_member_state(segment_stage.state, member, stage_state)}
    end)
  end

  @doc """
  The `t:VisionCore.Stereo.Stage.context/0` the stages get from the
  pipeline options: sizes, both calibrations scaled to the working size,
  and the stereo geometry derived from them.
  """
  @spec context(keyword()) :: Stage.context()
  def context(opts) do
    width = Keyword.fetch!(opts, :width)
    height = Keyword.fetch!(opts, :height)
    frame_width = Keyword.get(opts, :frame_width, width)
    frame_height = Keyword.get(opts, :frame_height, height)

    # Scaled to the working size, which rectification writes its images at.
    [left, right] =
      for key <- [:left_calibration_path, :right_calibration_path] do
        opts
        |> Keyword.fetch!(key)
        |> CameraCalibration.load!()
        |> CameraCalibration.scale_to(width, height)
      end

    [fx, _, cx, _, _, _, cy, _, _, _, _, _] = left.projection_matrix

    # Baseline from the right camera's rectified `P[0,3] = -fx × baseline`.
    baseline_m = if fx > 0, do: -Enum.at(right.projection_matrix, 3) / fx, else: 0.0

    %{
      width: width,
      height: height,
      frame_width: frame_width,
      frame_height: frame_height,
      left_calibration: left,
      right_calibration: right,
      focal_length_px: fx,
      baseline_m: baseline_m,
      principal_point: {cx, cy}
    }
  end

  defp log_ready(context, stages) do
    Logger.info(
      "#{__MODULE__} ready (#{context.width}×#{context.height}, " <>
        "fx=#{Float.round(context.focal_length_px, 2)} px, " <>
        "baseline=#{Float.round(context.baseline_m, 4)} m, " <>
        "stages: #{Enum.map_join(stages, " → ", &"#{&1.name} (#{where(compute(&1))})")})"
    )
  end

  # Where a run of stages computes, as `runs_on, implementation, backend`.
  defp where(%{runs_on: runs_on, implementation: implementation, backend: backend}),
    do: [runs_on, implementation, backend] |> Enum.reject(&is_nil/1) |> Enum.join(", ")
end
