defmodule VisionCore.Stereo.Bench do
  @moduledoc """
  Times a pipeline's stages on a board's GPU and checks their results
  against the same stages on EXLA, the way `mix vision_core.board_bench`
  runs it.

  `prepare/2` runs on your workstation: it compiles the stages for the
  board into a module cache, unless they are to be computed natively,
  makes a textured pair of frames, and records EXLA's outputs for it.
  `run/1` runs on the board, from the directory `prepare/2` wrote: it
  runs the pair through the cached modules, compares each output with
  EXLA's, and times successive pairs, the pipeline's per-pair cost
  without the cameras.

  The stages are the default ones, or a vehicle's (`:stages`), changed
  as `stages/1` says. `parse_overrides/2` and `parse_stage_names/2` read
  the task's `--set` and `--drop`.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.{NativeSegment, NxSegment, Pair, Pipeline, Segment}
  alias VisionCore.Stereo.Stage.Disparity

  @boards %{"ventuno_q" => :ventuno_q_defn_options, "c100" => :c100_defn_options}
  @outputs [:left, :right, :disparity, :depth, :cloud, :sharpness, :alignment, :metrics]
  @settings [:board, :size, :frame_size, :stages, :disparity, :overrides, :drop, :pairs, :compute]

  @doc """
  Writes into `dir` what `run/1` needs: the calibration, the module cache
  for `:board` (`"ventuno_q"` or `"c100"`), the frames and EXLA's outputs.

  ## Options

    * `:board` - required.
    * `:size` - the working `{width, height}`, required.
    * `:frame_size` - the frames' `{width, height}`; the working size by
      default.
    * `:stages`, `:disparity`, `:overrides`, `:drop` - the stages to time;
      see `stages/1`.
    * `:pairs` - how many pairs `run/1` times. Defaults to 10.
    * `:compute` - `:nx` (the default), compiled for the board's GPU, or
      `:native`, in the board's `stereo_match`.
  """
  @spec prepare(Path.t(), keyword()) :: :ok
  def prepare(dir, opts) do
    board = Keyword.fetch!(opts, :board)
    Map.has_key?(@boards, board) || raise ArgumentError, "unknown board #{inspect(board)}"
    {width, height} = Keyword.fetch!(opts, :size)
    {frame_width, frame_height} = Keyword.get(opts, :frame_size, {width, height})
    File.mkdir_p!(dir)
    write_calibration(dir, frame_width, frame_height)
    settings = Keyword.take(opts, @settings)
    context = context(dir, settings)
    members = members(settings, context)
    cache = Path.join(dir, "cache")
    File.rm_rf!(cache)

    if Keyword.get(opts, :compute, :nx) == :nx do
      {:ok, _segment} =
        NxSegment.build(members, context,
          defn_options: Keyword.put(defn_options(board, cache), :cache_only, true)
        )
    end

    frames = frames(frame_width, frame_height, disparity_options(settings))
    {:ok, segment} = NxSegment.build(members, context, defn_options: [compiler: EXLA])
    {:ok, reference, _segment} = Segment.run(NxSegment, pair(frames, context), segment, :infinity)
    term = %{settings: settings, frames: frames, reference: outputs(reference)}
    File.write!(Path.join(dir, "bench.term"), :erlang.term_to_binary(term))
  end

  @doc """
  The stages a benchmark of `settings` times: `:stages`, `{module, opts}`
  or modules, `Pipeline.default_stages/0` by default; `:disparity`
  merged into the Disparity stage's options, then each
  `{stage_name, options}` of `:overrides` into the options of the stage
  of that name (`Pipeline.stage_name/1`); without the stages `:drop`
  names.
  """
  @spec stages(keyword()) :: [{module(), keyword()}]
  def stages(settings) do
    disparity = Keyword.get(settings, :disparity, [])
    overrides = Keyword.get(settings, :overrides, [])
    drop = Keyword.get(settings, :drop, [])

    for {module, opts} <-
          settings |> Keyword.get(:stages, Pipeline.default_stages()) |> normalized(),
        name = Pipeline.stage_name(module),
        name not in drop do
      opts = if module == Disparity, do: Keyword.merge(opts, disparity), else: opts
      {module, Keyword.merge(opts, Keyword.get(overrides, name, []))}
    end
  end

  @doc """
  The `:overrides` that `stage.setting=value` texts give `stages`, a
  stage list: each value read as its setting's type. `{:error, reason}`
  for a text naming no stage of the list, or a setting its stage does
  not declare (`c:VisionCore.Stereo.NxStage.option_specs/0`), or a value
  of another type.
  """
  @spec parse_overrides([String.t()], [module() | {module(), keyword()}]) ::
          {:ok, keyword(keyword())} | {:error, String.t()}
  def parse_overrides(texts, stages) do
    Enum.reduce_while(texts, {:ok, []}, fn text, {:ok, overrides} ->
      case parse_override(text, normalized(stages)) do
        {:ok, stage, setting, parsed} ->
          stage_overrides = Keyword.merge(Keyword.get(overrides, stage, []), [{setting, parsed}])
          {:cont, {:ok, Keyword.merge(overrides, [{stage, stage_overrides}])}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  The stage names `names` gives, each the name of a stage of `stages`;
  `{:error, reason}` for one that names none.
  """
  @spec parse_stage_names([String.t()], [module() | {module(), keyword()}]) ::
          {:ok, [atom()]} | {:error, String.t()}
  def parse_stage_names(names, stages) do
    known = stages |> normalized() |> Map.new(fn {module, _opts} -> named_stage(module) end)

    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, found} ->
      case Map.fetch(known, name) do
        {:ok, {stage, _module}} -> {:cont, {:ok, found ++ [stage]}}
        :error -> {:halt, {:error, unknown_stage(name, known)}}
      end
    end)
  end

  @doc """
  Runs the benchmark `prepare/2` wrote into `dir` and returns its report:
  how each output differs from EXLA's, the time of each pair in µs, and
  a `BENCH` line of medians in ms: `total_ms`, a pair's send, wait and
  download; `dispatch_ms`, from its send to the device's reply;
  `collect_ms`, the download of its outputs; `gpu_ms`, the GPU's busy
  time per pair (`drm_gpu_ns/1`), `n/a` where the DRM driver does not
  report it; `build_ms`, `first_pair_ms`, and `download_bytes`, the size
  of a pair's outputs.
  """
  @spec run(Path.t()) :: String.t()
  def run(dir) do
    %{settings: settings, frames: frames, reference: reference} =
      dir |> Path.join("bench.term") |> File.read!() |> :erlang.binary_to_term()

    context = context(dir, settings)
    build_start_us = System.monotonic_time(:microsecond)
    {backend, segment} = segment(settings, context, Path.join(dir, "cache"))
    first_pair_start_us = System.monotonic_time(:microsecond)
    {:ok, result, segment} = Segment.run(backend, pair(frames, context), segment, :infinity)
    first_pair_end_us = System.monotonic_time(:microsecond)
    pair_count = Keyword.get(settings, :pairs, 10)
    gpu_start_ns = gpu_ns()

    {pair_times, segment} =
      Enum.map_reduce(1..pair_count, segment, fn _pair_number, segment ->
        time_pair(backend, pair(frames, context), segment)
      end)

    gpu_ms = gpu_ms_per_pair(gpu_start_ns, gpu_ns(), pair_count)

    differences =
      for {key, want} <- reference, do: "#{key}: #{compare(outputs(result)[key], want)}"

    totals = Enum.map(pair_times, & &1.total_us)

    summary =
      "BENCH total_ms=#{median_ms(totals)} " <>
        "dispatch_ms=#{median_ms(Enum.map(pair_times, & &1.dispatch_us))} " <>
        "collect_ms=#{median_ms(Enum.map(pair_times, & &1.collect_us))} gpu_ms=#{gpu_ms} " <>
        "build_ms=#{div(first_pair_start_us - build_start_us, 1000)} " <>
        "first_pair_ms=#{div(first_pair_end_us - first_pair_start_us, 1000)} " <>
        "download_bytes=#{download_bytes(segment)}"

    Enum.join(
      differences ++ ["us per pair: #{inspect(totals)}, median #{median(totals)}", summary],
      "\n"
    )
  end

  @doc """
  The GPU time, in ns, that the DRM clients whose `fdinfos` are given
  have used: the sum of their `drm-engine-gpu` counters, each client
  (`drm-client-id`) counted once however many descriptors share it;
  `nil` when none reports the counter, as on a GPU whose driver names
  its engines otherwise.
  """
  @spec drm_gpu_ns([String.t()]) :: non_neg_integer() | nil
  def drm_gpu_ns(fdinfos) do
    counters =
      for fdinfo <- fdinfos,
          [_line, gpu_ns] <- [Regex.run(~r/^drm-engine-gpu:\s+(\d+)/m, fdinfo)],
          into: %{},
          do: {client_id(fdinfo), String.to_integer(gpu_ns)}

    if counters == %{}, do: nil, else: counters |> Map.values() |> Enum.sum()
  end

  defp time_pair(backend, pair, segment) do
    start_us = System.monotonic_time(:microsecond)
    {:ok, request} = backend.send_request(pair, segment)
    {:ok, outputs, segment, _done_ns} = backend.await(request, segment, :infinity)
    reply_us = System.monotonic_time(:microsecond)
    {:ok, _pair} = backend.collect(pair, outputs, segment, :infinity)
    end_us = System.monotonic_time(:microsecond)

    {%{
       total_us: end_us - start_us,
       dispatch_us: reply_us - start_us,
       collect_us: end_us - reply_us
     }, segment}
  end

  defp median(values), do: values |> Enum.sort() |> Enum.at(div(length(values), 2))
  defp median_ms(values_us), do: median(values_us) / 1000

  defp gpu_ms_per_pair(start_ns, end_ns, pair_count)
       when is_integer(start_ns) and is_integer(end_ns),
       do: Float.round((end_ns - start_ns) / pair_count / 1.0e6, 2)

  defp gpu_ms_per_pair(_start_ns, _end_ns, _pair_count), do: "n/a"

  # The last output's offset, in 32-bit words, plus its size.
  defp download_bytes(%{layout: [_ | _] = layout}) do
    {_key, shape, {_kind, bits}, offset} = List.last(layout)
    offset * 4 + div(Tuple.product(shape) * bits, 8)
  end

  defp download_bytes(_segment), do: 0

  # The GPU time this BEAM's render nodes have used.
  defp gpu_ns do
    fd_dir = "/proc/#{System.pid()}/fd"

    fdinfos =
      for fd <- File.ls!(fd_dir),
          {:ok, target} <- [File.read_link(Path.join(fd_dir, fd))],
          String.contains?(target, "renderD"),
          {:ok, fdinfo} <- [File.read("/proc/#{System.pid()}/fdinfo/#{fd}")],
          do: fdinfo

    drm_gpu_ns(fdinfos)
  end

  # A descriptor without a client id is a client of its own.
  defp client_id(fdinfo) do
    case Regex.run(~r/^drm-client-id:\s+(\d+)/m, fdinfo) do
      [_line, id] -> id
      nil -> make_ref()
    end
  end

  defp normalized(stages), do: Enum.map(stages, &with_options/1)

  defp with_options({module, opts}), do: {module, opts}
  defp with_options(module), do: {module, []}

  defp named_stage(module) do
    stage = Pipeline.stage_name(module)
    {Atom.to_string(stage), {stage, module}}
  end

  defp parse_override(text, stages) do
    known = Map.new(stages, fn {module, _opts} -> named_stage(module) end)

    with [path, text_value] <- String.split(text, "=", parts: 2),
         [stage_text, setting_text] <- String.split(path, ".", parts: 2),
         {:ok, {stage, module}} <- fetch_stage(known, stage_text),
         {:ok, setting, spec} <- fetch_setting(module, setting_text),
         {:ok, parsed} <- parse_value(spec.type, text_value) do
      {:ok, stage, setting, parsed}
    else
      {:error, reason} -> {:error, "#{text}: #{reason}"}
      _parts -> {:error, "#{text}: expected stage.setting=value"}
    end
  end

  defp fetch_stage(known, stage_text) do
    case Map.fetch(known, stage_text) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, unknown_stage(stage_text, known)}
    end
  end

  defp unknown_stage(name, known),
    do: "no stage named #{name}; they are #{known |> Map.keys() |> Enum.join(", ")}"

  defp fetch_setting(module, setting_text) do
    specs =
      if Code.ensure_loaded?(module) and function_exported?(module, :option_specs, 0),
        do: module.option_specs(),
        else: []

    case Enum.find(specs, fn {setting, _spec} -> Atom.to_string(setting) == setting_text end) do
      {setting, spec} ->
        {:ok, setting, spec}

      nil ->
        settings = Enum.map_join(specs, ", ", fn {setting, _spec} -> setting end)
        {:error, "#{inspect(module)} has no setting #{setting_text}; it has #{settings}"}
    end
  end

  defp parse_value(:integer, text) do
    case Integer.parse(text) do
      {integer, ""} -> {:ok, integer}
      _not_integer -> {:error, "#{text} is not an integer"}
    end
  end

  defp parse_value(:double, text) do
    case Float.parse(text) do
      {number, ""} -> {:ok, number}
      _not_number -> {:error, "#{text} is not a number"}
    end
  end

  defp parse_value(:bool, "true"), do: {:ok, true}
  defp parse_value(:bool, "false"), do: {:ok, false}
  defp parse_value(:bool, text), do: {:error, "#{text} is not true or false"}
  defp parse_value(:string, text), do: {:ok, text}

  defp disparity_options(settings) do
    settings |> stages() |> List.keyfind(Disparity, 0, {Disparity, []}) |> elem(1)
  end

  defp defn_options(board, cache), do: apply(NxSegment, Map.fetch!(@boards, board), [cache])

  # The unit's matcher server, or one of the benchmark's own where none runs.
  defp matcher do
    case Process.whereis(VisionCore.Stereo.Matcher) do
      nil ->
        path = Application.get_env(:vision_core, :stereo_match_path)
        {:ok, matcher} = VisionCore.Stereo.Matcher.start_link(name: nil, path: path)
        matcher

      matcher ->
        matcher
    end
  end

  # The backend and segment the stages run in: compiled from the cache, or in stereo_match.
  defp segment(settings, context, cache) do
    members = members(settings, context)

    case Keyword.get(settings, :compute, :nx) do
      :nx ->
        options = defn_options(settings[:board], cache)
        {:ok, segment} = NxSegment.build(members, context, defn_options: options)
        {NxSegment, segment}

      :native ->
        {:ok, segment} = NativeSegment.build(members, context, matcher: matcher())
        {NativeSegment, segment}
    end
  end

  defp context(dir, settings) do
    {width, height} = settings[:size]
    {frame_width, frame_height} = Keyword.get(settings, :frame_size, {width, height})

    Pipeline.context(
      left_calibration_path: Path.join(dir, "left.yaml"),
      right_calibration_path: Path.join(dir, "right.yaml"),
      width: width,
      height: height,
      frame_width: frame_width,
      frame_height: frame_height
    )
  end

  defp members(settings, context) do
    for {module, opts} <- stages(settings) do
      {:ok, state} = module.init(opts, context)
      %{module: module, name: module, state: state}
    end
  end

  # A rectified pair 20 cm apart, the left camera's focal length 0.6 frame widths.
  defp write_calibration(dir, width, height) do
    fx = width * 0.6
    {cx, cy} = {width / 2, height / 2}

    for {side, tx} <- [left: 0.0, right: -fx * 0.2] do
      calibration = %CameraCalibration{
        width: width,
        height: height,
        distortion_model: "plumb_bob",
        distortion_coefficients: [0.0, 0.0, 0.0, 0.0, 0.0],
        camera_matrix: [fx, 0.0, cx, 0.0, fx, cy, 0.0, 0.0, 1.0],
        rectification_matrix: [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
        projection_matrix: [fx, 0.0, cx, tx, 0.0, fx, cy, 0.0, 0.0, 0.0, 1.0, 0.0]
      }

      File.write!(
        Path.join(dir, "#{side}.yaml"),
        CameraCalibration.to_yaml(calibration, "#{side}")
      )
    end
  end

  # A random texture, the right frame seeing it shifted by a quarter of the disparities searched.
  defp frames(width, height, disparity) do
    shift = div(Keyword.get(disparity, :num_disparities, 64), 4)

    {texture, _key} =
      Nx.Random.randint(Nx.Random.key(1), 0, 256, shape: {height, width + shift}, type: :s32)

    texture = Nx.as_type(texture, :u8)

    {Nx.to_binary(texture[[.., 0..(width - 1)]]),
     Nx.to_binary(texture[[.., shift..(width + shift - 1)]])}
  end

  defp pair({left, right}, context) do
    frame = fn grey, label ->
      %Frame{
        label: label,
        grey: grey,
        width: context.frame_width,
        height: context.frame_height,
        capture_ns: 0
      }
    end

    %Pair{
      left_frame: frame.(left, "left"),
      right_frame: frame.(right, "right"),
      geometry: context
    }
  end

  # The pair's outputs, its depth and cloud binaries as tensors.
  defp outputs(pair) do
    for key <- @outputs, output = Map.get(pair, key), output != nil, into: %{} do
      output =
        case {key, output} do
          {:depth, binary} -> Nx.from_binary(binary, :u16)
          {:cloud, binary} -> Nx.from_binary(binary, :f32)
          {_key, %Nx.Tensor{} = tensor} -> Nx.backend_copy(tensor, Nx.BinaryBackend)
          {_key, other} -> other
        end

      {key, output}
    end
  end

  # Elements further apart than 1e-3, relative above 1, NaN matching NaN.
  defp compare(%Nx.Tensor{} = got, %Nx.Tensor{} = want) do
    {got, want} = {Nx.as_type(got, :f32), Nx.as_type(want, :f32)}
    nan = Nx.logical_and(Nx.is_nan(got), Nx.is_nan(want))
    error = Nx.select(nan, 0.0, Nx.abs(Nx.subtract(got, want)))
    differing = error |> Nx.greater(Nx.multiply(Nx.max(Nx.abs(want), 1.0), 1.0e-3)) |> Nx.sum()

    "#{Nx.to_number(differing)}/#{Nx.size(want)} differ, max #{Nx.to_number(Nx.reduce_max(error))}"
  end

  defp compare(same, same), do: "same"
  defp compare(got, want), do: "#{inspect(got, limit: 6)} vs #{inspect(want, limit: 6)}"
end
