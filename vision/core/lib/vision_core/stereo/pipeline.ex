defmodule VisionCore.Stereo.Pipeline do
  @moduledoc """
  Runs each submitted left/right pair through a list of
  `VisionCore.Stereo.Stage`s and sends the finished
  `VisionCore.Stereo.Pair` to its listeners as `{:stereo_pair, pair}`.

  The default stages, from `default_stages/1`, all but `Quality` written
  in Nx (`VisionCore.Stereo.NxStage`):

      Rectify      # camera frames → rectified grey images at the pipeline's size
      Match        # disparity, libSGM's semi-global matching
      PostFilter   # median filter on the disparity
      Speckle      # drops small islands of disparity
      Alignment    # measures the rectified images' row offset
      Temporal     # smoothing of the disparity over time
      Depth        # disparity → metric depth
      PointCloud   # depth → decimated point cloud
      Quality      # disparity statistics for the log line

  A stage list is checked at start: every field a stage requires must be
  provided by a stage before it, and the stages together must provide
  the disparity and depth listeners consume. Each stage is timed, and
  the timings are logged with the metrics stages report.

  Consecutive Nx stages are compiled at start into one
  `VisionCore.Stereo.NxSegment`, and so, through `nx_iree`, one module
  on the device; it runs and is timed as one stage named after its
  members.

  Once a pair is done, whether it succeeded or not, the process that
  submitted it receives `:stereo_pipeline_ready`;
  `VisionCore.Stereo.Pairer` submits the next pair then. When the stage
  list starts with a segment, a pair is done once that segment's device
  work is: the pair's outputs are downloaded and the later stages run
  while the next pair's device work does, and it reaches the listeners
  then, or after `:flush_after_ms` if no pair follows.

  ## Options

    * `:left_calibration_path`, `:right_calibration_path` (required) —
      `camera_calibration_parsers` YAMLs. The right camera's projection
      matrix `P_right[0,3] = -fx × T` encodes the baseline.
    * `:width`, `:height` (required) — the size the stages work at. The
      calibrations are scaled to it.
    * `:frame_width`, `:frame_height` (`:width`, `:height`) — the size
      of the submitted frames.
    * `:stages` (`default_stages/0`) — modules or `{module, opts}`.
    * `:defn_options` — how Nx stages are compiled; see
      `VisionCore.Stereo.NxSegment.defn_options/1` for the default.
    * `:flush_after_ms` (`100`) — how long a pair waits for the next one
      before it is finished alone; see below.
    * `:name` (`__MODULE__`).
  """
  use GenServer
  require Logger

  @default_flush_after_ms 100

  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.{NxSegment, NxStage, Pair, Stage, StageTimer}

  @consumed [:left, :right, :disparity, :disparity_range, :disparity_bytes, :depth, :depth_m]

  @doc "Starts the pipeline; see the module doc for `opts`."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The default stages, with `overrides` merged into the options of the
  stage they name: `default_stages(match: [num_disparities: 128])`.
  """
  @spec default_stages(keyword()) :: [{module(), keyword()}]
  def default_stages(overrides \\ []) do
    for module <- [
          Stage.Rectify,
          Stage.Match,
          Stage.PostFilter,
          Stage.Speckle,
          Stage.Alignment,
          Stage.Temporal,
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

  @doc "The settings the stages accept while running, as `{key, spec}`."
  def option_specs(server), do: GenServer.call(server, :option_specs)

  @doc "The settings in force."
  def options(server), do: GenServer.call(server, :options)

  @doc """
  Changes settings from the next pair on. Returns the settings now in
  force, or why the request was refused, in which case none changed.
  """
  def set_options(server, options), do: GenServer.call(server, {:set_options, options})

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
         |> group_nx_stages(context, context.defn_options),
       listeners: [],
       timer: StageTimer.new(window: 30, label: "pipeline"),
       last_start_ns: nil,
       pending: nil,
       flush_after_ms: Keyword.get(opts, :flush_after_ms, @default_flush_after_ms)
     }}
  end

  @impl GenServer
  def handle_call(:option_specs, _from, state),
    do: {:reply, Enum.flat_map(state.stages, &stage_option_specs/1), state}

  def handle_call(:options, _from, state), do: {:reply, current_options(state), state}

  def handle_call({:set_options, options}, _from, state) do
    case Enum.reduce_while(options, {:ok, state.stages}, &set_option/2) do
      {:ok, stages} ->
        state = %{state | stages: stages}
        {:reply, {:ok, current_options(state)}, state}

      {:error, _reason} = error ->
        {:reply, error, state}
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
      [%{module: NxSegment} = first | _rest] ->
        {:noreply, dispatch(pair, first, start_ns, submitter, state)}

      stages ->
        {outcome, stages, timer} = run_stages(pair, stages, state.timer)
        send(submitter, :stereo_pipeline_ready)
        {:noreply, finish_pair(outcome, start_ns, %{state | stages: stages, timer: timer})}
    end
  end

  @impl GenServer
  def handle_info({:flush, ref}, %{pending: %{ref: ref}} = state), do: {:noreply, flush(state)}
  def handle_info({:flush, _stale}, state), do: {:noreply, state}

  # `pair`'s device work runs while the pending pair is finished; it then becomes the pending one.
  defp dispatch(pair, first, start_ns, submitter, state) do
    task = Task.async(fn -> timed(fn -> NxSegment.dispatch(pair, first.state) end) end)
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
        finish_pair({:error, NxSegment, reason}, start_ns, state)
    end
  end

  defp flush(%{pending: nil} = state), do: state

  defp flush(%{pending: pending, stages: [first | rest]} = state) do
    {collect_ns, pair} =
      timed(fn -> NxSegment.collect(pending.pair, pending.outputs, first.state) end)

    segment_ns = pending.ns + collect_ns
    pair = %{pair | device_ms: segment_ns / 1_000_000}
    timer = StageTimer.record(state.timer, first.name, segment_ns)
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
            {:ok, pair, stage_state} when stage.module == NxSegment ->
              pair = %{pair | device_ms: pair.device_ms + elapsed_ns / 1_000_000}
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

  # Each run of consecutive Nx stages becomes one segment stage.
  defp group_nx_stages(stages, context, defn_options) do
    stages
    |> Enum.chunk_by(&NxStage.nx_stage?(&1.module))
    |> Enum.flat_map(fn [first | _] = run ->
      if NxStage.nx_stage?(first.module),
        do: [segment_stage!(run, context, defn_options)],
        else: run
    end)
  end

  defp segment_stage!(members, context, defn_options) do
    name = members |> Enum.map_join("+", & &1.name) |> String.to_atom()

    case NxSegment.build(members, context, defn_options) do
      {:ok, segment} -> %{module: NxSegment, name: name, opts: [], state: segment}
      {:error, reason} -> raise ArgumentError, "#{name} cannot start: #{reason}"
    end
  end

  defp init_stage!(stage, context) do
    case stage.module.init(stage.opts, context) do
      {:ok, stage_state} -> Map.put(stage, :state, stage_state)
      {:error, reason} -> raise ArgumentError, "#{inspect(stage.module)} cannot start: #{reason}"
    end
  end

  defp reinit_stage!(%{module: NxSegment, state: segment} = stage, context) do
    members = Enum.map(segment.members, &reinit_stage!(&1, context))
    %{stage | state: NxSegment.reload(segment, members, context)}
  end

  # Settings changed while running survive the rebuild.
  defp reinit_stage!(stage, context) do
    opts = Keyword.merge(stage.opts, Map.to_list(stage_options(stage)))
    init_stage!(%{stage | opts: opts}, context)
  end

  defp stage_option_specs(%{module: NxSegment, state: segment}),
    do: NxSegment.option_specs(segment)

  defp stage_option_specs(stage) do
    if function_exported?(stage.module, :option_specs, 0),
      do: stage.module.option_specs(),
      else: []
  end

  defp stage_options(stage) do
    if function_exported?(stage.module, :options, 1),
      do: stage.module.options(stage.state),
      else: %{}
  end

  defp current_options(state),
    do: Enum.reduce(state.stages, %{}, &Map.merge(&2, stage_options(&1)))

  defp set_option({key, value}, {:ok, stages}) do
    case Enum.find_index(stages, &List.keymember?(stage_option_specs(&1), key, 0)) do
      nil ->
        {:halt, {:error, "unknown or invalid stereo setting #{inspect(key)}: #{inspect(value)}"}}

      index ->
        stage = Enum.at(stages, index)

        case stage.module.set_option(stage.state, key, value) do
          {:ok, stage_state} ->
            {:cont, {:ok, List.replace_at(stages, index, %{stage | state: stage_state})}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end
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
