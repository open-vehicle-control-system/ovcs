defmodule VisionCore.Stereo.Pipeline do
  @moduledoc """
  Runs each submitted left/right pair through a list of
  `VisionCore.Stereo.Stage`s and sends the finished
  `VisionCore.Stereo.Pair` to its listeners as `{:stereo_pair, pair}`.

  The default stages, from `default_stages/1`, all written in Nx
  (`VisionCore.Stereo.NxStage`):

      Rectification   # camera frames → rectified grey images at the pipeline's size
      Sharpness       # each image's sharpness, to compare the cameras' focus
      Disparity       # disparity, libSGM's semi-global matching
      MedianFilter    # median filter on the disparity
      SpeckleFilter   # drops small islands of disparity
      RowAlignment    # measures the rectified images' row offset
      TemporalFilter  # smoothing of the disparity over time
      Depth           # disparity → metric depth
      PointCloud      # depth → decimated point cloud
      Quality         # disparity statistics for the log line

  A stage list is checked at start: every field a stage requires must be
  provided by a stage before it, and the stages together must provide
  the disparity and depth listeners consume. Each stage is timed, and
  the timings are logged with the metrics stages report.

  Consecutive Nx stages are compiled at start into one
  `VisionCore.Stereo.NxSegment`, and so, through `nx_iree`, one module
  on the device; it runs and is timed as one stage named after its
  members. With `compute: :native`, consecutive stages that have a
  native implementation (`VisionCore.Stereo.NativeSegment.supported?/1`),
  every default one, run instead as one `VisionCore.Stereo.NativeSegment`
  in the `stereo_match` Port, a pair's one round trip, with each
  member's time logged under its name too. A stage's
  `c:VisionCore.Stereo.NxStage.compute/1` overrides the pipeline's
  choice for that stage, as `Disparity`'s `:matcher` does. Stages
  without a native implementation run between the segments around them,
  which take their outputs as inputs.

  Once the pipeline can take another pair, the process that submitted
  the last one receives `:stereo_pipeline_ready`;
  `VisionCore.Stereo.Pairer` submits the next pair then. Without a
  segment first, that is once the pair is done, whether it succeeded or
  not. When the stage list starts with a compiled segment, a pair is
  done once its device work is: the pair's outputs are collected and
  the later stages run while the next pair's device work does, and it
  reaches the listeners then, or after `:flush_after_ms` if no pair
  follows. When it starts with a native segment, two pairs are at the
  Port at once, so it computes one while the other's frames and outputs
  go through the pipes: the next pair is taken once the earlier of the
  two is back, and that one is then collected, run through the later
  stages and sent to the listeners. A live setting of a native stage
  then applies from the second pair submitted after the change.

  ## Options

    * `:left_calibration_path`, `:right_calibration_path` (required) —
      `camera_calibration_parsers` YAMLs. The right camera's projection
      matrix `P_right[0,3] = -fx × T` encodes the baseline.
    * `:width`, `:height` (required) — the size the stages work at. The
      calibrations are scaled to it.
    * `:frame_width`, `:frame_height` (`:width`, `:height`) — the size
      of the submitted frames.
    * `:stages` (`default_stages/0`) — modules or `{module, opts}`.
    * `:compute` (`:nx`) — `:native` runs the stages that have a native
      implementation natively, through `VisionCore.Stereo.Matcher`, which
      must be running; `:nx` compiles them.
    * `:defn_options` — how Nx stages are compiled; see
      `VisionCore.Stereo.NxSegment.defn_options/1` for the default.
    * `:flush_after_ms` (`100`) — how long a pair a compiled segment
      returned waits for the next one before it is finished alone; see
      above.
    * `:name` (`__MODULE__`).
  """
  use GenServer
  require Logger

  @default_flush_after_ms 100

  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.{NativeSegment, NxSegment, NxStage, Pair, Stage, StageTimer}

  @consumed [:left, :right, :disparity, :disparity_range, :disparity_bytes, :depth]
  @segments [NxSegment, NativeSegment]
  # Pairs at the Port at once when a native segment runs first.
  @in_flight 2

  @doc "Starts the pipeline; see the module doc for `opts`."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The default stages, with `overrides` merged into the options of the
  stage they name: `default_stages(disparity: [num_disparities: 128])`.
  """
  @spec default_stages(keyword()) :: [{module(), keyword()}]
  def default_stages(overrides \\ []) do
    for module <- [
          Stage.Rectification,
          Stage.Sharpness,
          Stage.Disparity,
          Stage.MedianFilter,
          Stage.SpeckleFilter,
          Stage.RowAlignment,
          Stage.TemporalFilter,
          Stage.Depth,
          Stage.PointCloud,
          Stage.Quality
        ] do
      {module, Keyword.get(overrides, stage_name(module), [])}
    end
  end

  @doc "Sends every later `{:stereo_pair, %Pair{}}` to `listener` as a cast."
  def register_listener(server, listener),
    do: GenServer.cast(server, {:register_listener, listener})

  @doc "Queues one left/right frame pair; the caller receives `:stereo_pipeline_ready` once it is done."
  def submit(server, %Frame{} = left, %Frame{} = right),
    do: GenServer.cast(server, {:submit, left, right, self()})

  @typedoc "A stage's settings, as `stage_options/1` lists them."
  @type stage_options :: %{
          stage: atom(),
          module: module(),
          summary: String.t(),
          specs: [{atom(), Stage.option_spec()}],
          values: %{atom() => term()}
        }

  @doc """
  Every stage in pipeline order, the members of a compiled segment
  among them: its name, module, summary, settings (`applies` filled in)
  and their values.
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

  @doc """
  Reloads the calibration from the YAMLs on disk and rebuilds every
  stage with its settings in force, so the next pair reflects the new
  geometry. `paths` (`:left_calibration_path`, `:right_calibration_path`)
  replaces the YAMLs to read, for this and later reloads, once they load.
  """
  def reload_calibration(server, paths \\ []),
    do: GenServer.call(server, {:reload_calibration, paths})

  @impl GenServer
  def init(opts) do
    context = context(opts)
    compute = Keyword.get(opts, :compute, :nx)

    if compute not in [:nx, :native],
      do: raise(ArgumentError, "compute is :nx or :native, got #{inspect(compute)}")

    stages =
      opts
      |> Keyword.get_lazy(:stages, &default_stages/0)
      |> Enum.map(&normalise_stage/1)

    check_order!(stages)
    log_ready(context, stages)

    {:ok,
     %{
       opts: opts,
       context: context,
       stages:
         stages
         |> Enum.map(&init_stage!(&1, context))
         |> group_stages(compute, context),
       listeners: [],
       timer: StageTimer.new(window: 30, label: "pipeline"),
       last_start_ns: nil,
       pending: nil,
       in_flight: :queue.new(),
       last_reply_ns: nil,
       waiting_submitter: nil,
       flush_after_ms: Keyword.get(opts, :flush_after_ms, @default_flush_after_ms)
     }}
  end

  @impl GenServer
  def handle_call(:stage_options, _from, state) do
    stages =
      for stage <- state.stages,
          member <- members(stage),
          do: Map.put(describe(member), :compute, compute(stage, state.context))

    {:reply, stages, state}
  end

  def handle_call({:set_options, name, options}, _from, state) do
    with {:ok, location, stage} <- find_stage(state.stages, name),
         {:ok, stage_state} <- apply_options(stage, options) do
      stages = put_stage_state(state.stages, location, stage_state)
      {:reply, {:ok, values(%{stage | state: stage_state})}, %{state | stages: stages}}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reload_calibration, paths}, _from, state) do
    opts = Keyword.merge(state.opts, paths)
    context = context(opts)
    stages = Enum.map(state.stages, &reinit_stage!(&1, context))

    Logger.info(
      "#{__MODULE__} reloaded calibration " <>
        "(fx=#{Float.round(context.focal_length_px, 2)} px, " <>
        "baseline=#{Float.round(context.baseline_m, 4)} m)"
    )

    {:reply, :ok, %{state | opts: opts, context: context, stages: stages}}
  rescue
    error ->
      Logger.warning("#{__MODULE__}: reload_calibration failed: #{inspect(error)}")
      {:reply, {:error, error}, state}
  end

  @impl GenServer
  def handle_cast({:register_listener, listener}, state),
    do: {:noreply, %{state | listeners: state.listeners ++ [listener]}}

  def handle_cast({:submit, %Frame{} = left, %Frame{} = right, submitter}, state) do
    start_ns = System.monotonic_time(:nanosecond)
    pair = %Pair{left_frame: left, right_frame: right, geometry: state.context}

    case state.stages do
      [%{module: NativeSegment} = first | _rest] ->
        {:noreply, send_native(pair, first, start_ns, submitter, state)}

      [%{module: module} = first | _rest] when module in @segments ->
        {:noreply, dispatch(pair, first, start_ns, submitter, state)}

      stages ->
        {outcome, stages, timer} = run_stages(pair, stages, state.timer)
        send(submitter, :stereo_pipeline_ready)
        {:noreply, finish_pair(outcome, start_ns, %{state | stages: stages, timer: timer})}
    end
  end

  @impl GenServer
  def handle_info(message, state) do
    with {:value, sent} <- :queue.peek(state.in_flight),
         result when result != :no_reply <-
           NativeSegment.response(message, sent.request_id, sent.segment) do
      {:noreply, receive_native(result, sent, state)}
    else
      _other -> other_info(message, state)
    end
  end

  defp other_info({:flush, ref}, %{pending: %{ref: ref}} = state), do: {:noreply, flush(state)}
  defp other_info(_message, state), do: {:noreply, state}

  defp send_native(pair, first, start_ns, submitter, state) do
    case NativeSegment.send_request(pair, first.state) do
      {:ok, request_id} ->
        sent = %{
          request_id: request_id,
          pair: pair,
          segment: first.state,
          start_ns: start_ns,
          sent_ns: System.monotonic_time(:nanosecond)
        }

        state = %{state | in_flight: :queue.in(sent, state.in_flight)}

        if :queue.len(state.in_flight) < @in_flight do
          send(submitter, :stereo_pipeline_ready)
          state
        else
          %{state | waiting_submitter: submitter}
        end

      {:error, reason} ->
        send(submitter, :stereo_pipeline_ready)
        finish_pair({:error, NativeSegment, reason}, start_ns, state)
    end
  end

  # The segment's time runs from when the Port could start on the pair.
  defp receive_native(result, sent, state) do
    reply_ns = System.monotonic_time(:nanosecond)
    port_ns = reply_ns - max(sent.sent_ns, state.last_reply_ns || sent.sent_ns)
    state = %{state | in_flight: :queue.drop(state.in_flight), last_reply_ns: reply_ns}

    state =
      case result do
        {:ok, outputs, segment} ->
          [first | rest] = state.stages
          {collect_ns, pair} = timed(fn -> NativeSegment.collect(sent.pair, outputs, segment) end)
          segment_ns = port_ns + collect_ns

          timer =
            state.timer
            |> StageTimer.record(first.name, segment_ns)
            |> record_members(NativeSegment, segment)

          pair = %{pair | device_ms: segment_ns / 1_000_000}
          {outcome, rest, timer} = run_stages(pair, rest, timer)
          finish_pair(outcome, sent.start_ns, %{state | stages: [first | rest], timer: timer})

        {:error, reason} ->
          finish_pair({:error, NativeSegment, reason}, sent.start_ns, state)
      end

    case state.waiting_submitter do
      nil ->
        state

      submitter ->
        send(submitter, :stereo_pipeline_ready)
        %{state | waiting_submitter: nil}
    end
  end

  # `pair`'s device work runs while the pending pair is finished; it then becomes the pending one.
  defp dispatch(pair, %{module: module} = first, start_ns, submitter, state) do
    task = Task.async(fn -> timed(fn -> module.dispatch(pair, first.state) end) end)
    state = flush(state)
    {dispatch_ns, result} = Task.await(task, :infinity)
    send(submitter, :stereo_pipeline_ready)

    case result do
      {:ok, outputs, segment} ->
        state = %{state | stages: List.replace_at(state.stages, 0, %{first | state: segment})}
        ref = make_ref()
        Process.send_after(self(), {:flush, ref}, state.flush_after_ms)
        pending = %{ref: ref, pair: pair, outputs: outputs, ns: dispatch_ns, start_ns: start_ns}
        %{state | pending: pending}

      {:error, reason} ->
        finish_pair({:error, module, reason}, start_ns, state)
    end
  end

  defp flush(%{pending: nil} = state), do: state

  defp flush(%{pending: pending, stages: [%{module: module} = first | rest]} = state) do
    {collect_ns, pair} =
      timed(fn -> module.collect(pending.pair, pending.outputs, first.state) end)

    segment_ns = pending.ns + collect_ns
    pair = %{pair | device_ms: segment_ns / 1_000_000}

    timer =
      state.timer
      |> StageTimer.record(first.name, segment_ns)
      |> record_members(module, first.state)

    {outcome, rest, timer} = run_stages(pair, rest, timer)
    state = %{state | stages: [first | rest], timer: timer, pending: nil}
    finish_pair(outcome, pending.start_ns, state)
  end

  defp finish_pair(outcome, start_ns, state) do
    case outcome do
      {:ok, %Pair{} = pair} ->
        Enum.each(state.listeners, &GenServer.cast(&1, {:stereo_pair, pair}))

      {:error, module, reason} ->
        Logger.warning("#{__MODULE__}: #{inspect(module)} failed: #{inspect(reason)}")
    end

    timer =
      state.timer
      |> StageTimer.record(:total, System.monotonic_time(:nanosecond) - start_ns)
      |> StageTimer.record(:wall, elapsed_since(state.last_start_ns, start_ns))
      |> StageTimer.tick()

    %{state | timer: timer, last_start_ns: start_ns}
  end

  defp run_stages(pair, stages, timer) do
    {outcome, done, timer} =
      Enum.reduce(stages, {{:ok, pair}, [], timer}, fn
        stage, {{:ok, pair}, done, timer} ->
          {elapsed_ns, result} = timed(fn -> stage.module.run(pair, stage.state) end)
          timer = StageTimer.record(timer, stage.name, elapsed_ns)

          case result do
            {:ok, pair, stage_state} when stage.module in @segments ->
              pair = %{pair | device_ms: pair.device_ms + elapsed_ns / 1_000_000}
              timer = record_members(timer, stage.module, stage_state)
              {{:ok, pair}, [%{stage | state: stage_state} | done], timer}

            {:ok, pair, stage_state} ->
              {{:ok, pair}, [%{stage | state: stage_state} | done], timer}

            {:error, reason, stage_state} ->
              {{:error, stage.module, reason}, [%{stage | state: stage_state} | done], timer}
          end

        stage, {error, done, timer} ->
          {error, [stage | done], timer}
      end)

    {outcome, Enum.reverse(done), record_metrics(timer, outcome)}
  end

  defp record_members(timer, NativeSegment, segment) do
    segment.members
    |> Enum.zip(segment.times_us)
    |> Enum.reduce(timer, fn {member, time_us}, timer ->
      StageTimer.record(timer, member.name, time_us * 1_000)
    end)
  end

  defp record_members(timer, _module, _segment), do: timer

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

  defp normalise_stage({module, opts}) when is_atom(module) and is_list(opts),
    do: %{module: module, opts: opts, name: stage_name(module)}

  defp normalise_stage(module) when is_atom(module), do: normalise_stage({module, []})

  defp stage_name(module),
    do: module |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

  defp check_order!(stages) do
    provided =
      Enum.reduce(stages, MapSet.new([:left_frame, :right_frame]), fn stage, provided ->
        Code.ensure_loaded!(stage.module)

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

  defp defn_options(opts),
    do: Keyword.get_lazy(opts, :defn_options, fn -> NxSegment.defn_options(%{}) end)

  # Each run of consecutive native, or compiled, stages becomes one segment stage.
  defp group_stages(stages, compute, context) do
    stages
    |> Enum.chunk_by(&placement(&1, compute))
    |> Enum.flat_map(fn [first | _] = run ->
      case placement(first, compute) do
        :native ->
          [segment_stage!(run, NativeSegment, &NativeSegment.build(&1, context))]

        :compiled ->
          [segment_stage!(run, NxSegment, &NxSegment.build(&1, context, context.defn_options))]

        :plain ->
          run
      end
    end)
  end

  defp placement(stage, compute) do
    cond do
      not NxStage.nx_stage?(stage.module) ->
        :plain

      NativeSegment.supported?(stage.module) and
          (NxStage.compute(stage.module, stage.state) || compute) == :native ->
        :native

      true ->
        :compiled
    end
  end

  defp segment_stage!(members, module, build) do
    name = members |> Enum.map_join("+", & &1.name) |> String.to_atom()

    case build.(members) do
      {:ok, segment} -> %{module: module, name: name, opts: [], state: segment}
      {:error, reason} -> raise ArgumentError, "#{name} cannot start: #{reason}"
    end
  end

  defp init_stage!(stage, context) do
    case stage.module.init(stage.opts, context) do
      {:ok, stage_state} -> Map.put(stage, :state, stage_state)
      {:error, reason} -> raise ArgumentError, "#{inspect(stage.module)} cannot start: #{reason}"
    end
  end

  defp reinit_stage!(%{module: module, state: segment} = stage, context)
       when module in @segments do
    members = Enum.map(segment.members, &reinit_stage!(&1, context))
    %{stage | state: module.reload(segment, members, context)}
  end

  # Settings changed while running survive the rebuild.
  defp reinit_stage!(stage, context) do
    opts = Keyword.merge(stage.opts, Map.to_list(values(stage)))
    init_stage!(%{stage | opts: opts}, context)
  end

  defp members(%{module: module, state: segment}) when module in @segments,
    do: segment.members

  defp members(stage), do: [stage]

  defp compute(%{module: NativeSegment}, _context), do: NativeSegment.compute()
  defp compute(%{module: NxSegment}, context), do: NxSegment.compute(context.defn_options)
  defp compute(_stage, _context), do: %{runs_on: :cpu, implementation: :elixir, backend: nil}

  defp describe(stage) do
    %{
      stage: stage.name,
      module: stage.module,
      summary: summary(stage.module),
      specs: option_specs(stage.module),
      values: values(stage)
    }
  end

  defp summary(module) do
    if function_exported?(module, :summary, 0), do: module.summary(), else: ""
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

  # `{index, nil}` for a stage, `{index, member_index}` for a member of a segment.
  defp find_stage(stages, name) do
    stages
    |> Enum.with_index()
    |> Enum.find_value({:error, "no stereo stage #{inspect(name)}"}, fn
      {%{module: module, state: segment}, index} when module in @segments ->
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
      case specs[key] do
        nil ->
          {:halt, {:error, "#{stage.name}.#{key} is not a setting of the stage"}}

        %{applies: :build} ->
          {:halt, {:error, "#{stage.name}.#{key} is fixed when the stage starts"}}

        _live ->
          case stage.module.set_option(stage_state, key, value) do
            {:ok, stage_state} -> {:cont, {:ok, stage_state}}
            {:error, _reason} = error -> {:halt, error}
          end
      end
    end)
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

    # Scaled to the capture resolution, or rectification would upsample every frame.
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
      defn_options: defn_options(opts),
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
        "stages: #{Enum.map_join(stages, " → ", & &1.name)})"
    )
  end
end
