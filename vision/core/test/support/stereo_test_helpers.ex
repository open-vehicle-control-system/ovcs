defmodule VisionCore.Stereo.TestHelpers do
  @moduledoc """
  What the stereo tests share: calibration fixtures and the context of
  the stages built from them, test images and pairs, segments run on
  each backend, either on the stages of a segment (`run_nx/4`,
  `run_native/4`) or on one stage alone (`run_stage/5`), and pipelines
  started under a name the next test can take again (`start_pipeline/1`).

  Plain functions, imported where used:

      import VisionCore.Stereo.TestHelpers, only: [context: 3, run_stage: 4]

  Nx runs compile with EXLA unless a `compiler` says otherwise. Native
  runs need the `stereo_match` Port: tag their tests `:stereo_match`.
  `run_stage/5` starts a `VisionCore.Stereo.Matcher` of its own under
  the test's supervisor, so it takes the test process only.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Stereo.{Matcher, NativeSegment, NxSegment, NxStage, Pair, Pipeline, Segment}
  alias VisionCore.Stereo.Stage

  @calibration Path.expand("calibration", __DIR__)

  @typedoc "A stage to run: its module, or its module and the options to start it with."
  @type stage :: module() | {module(), keyword()}

  @typedoc "What a stage runs on: a pair, or the fields to put in one (`pair/1`)."
  @type input :: Pair.t() | keyword() | map()

  @doc """
  The file of `side`'s calibration in the fixture `calibration`:
  `:stereo`, `:identity` or `:distorted`.
  """
  @spec calibration_path(atom(), :left | :right) :: Path.t()
  def calibration_path(calibration, side),
    do: Path.join(@calibration, "#{calibration}_#{side}.yaml")

  @doc """
  The context the stages of a pipeline get from the fixture `calibration`,
  scaled to `width` × `height`. `frame_size` is the `{width, height}` of
  the frames submitted, the working size by default.
  """
  @spec context(
          atom(),
          pos_integer(),
          pos_integer(),
          {pos_integer(), pos_integer()} | nil
        ) :: Stage.context()
  def context(calibration, width, height, frame_size \\ nil) do
    {frame_width, frame_height} = frame_size || {width, height}

    Pipeline.context(
      left_calibration_path: calibration_path(calibration, :left),
      right_calibration_path: calibration_path(calibration, :right),
      width: width,
      height: height,
      frame_width: frame_width,
      frame_height: frame_height
    )
  end

  @doc """
  Starts a `VisionCore.Stereo.Pipeline` with `opts` linked to the test
  process, and returns what `VisionCore.Stereo.Pipeline.start_link/1`
  returns. The pipeline exits with the test process, and the next test
  starts only once it has: a pipeline busy in a NIF exits late, still
  holding its name.
  """
  @spec start_pipeline(keyword()) :: GenServer.on_start()
  def start_pipeline(opts) do
    with {:ok, pipeline} <- Pipeline.start_link(opts) do
      ExUnit.Callbacks.on_exit(fn -> await_exit(pipeline) end)
      {:ok, pipeline}
    end
  end

  defp await_exit(process) do
    monitor = Process.monitor(process)

    receive do
      {:DOWN, ^monitor, :process, _process, _reason} -> :ok
    after
      30_000 -> raise "#{inspect(process)} still runs 30 s after its test"
    end
  end

  @doc "The `stereo_match` binary the tests run, which `test_helper.exs` puts in the app env."
  @spec stereo_match_path() :: Path.t()
  def stereo_match_path, do: Application.fetch_env!(:vision_core, :stereo_match_path)

  @doc """
  A `stereo_match` to start a `VisionCore.Stereo.Matcher` on, written
  into `dir`: it reads its requests and never answers, until `dir` holds
  an `answer` file; started from then on, it is the real one.
  """
  @spec silent_stereo_match(Path.t()) :: Path.t()
  def silent_stereo_match(dir) do
    silent = Path.join(dir, "stereo_match")

    File.write!(silent, """
    #!/bin/sh
    if [ -e "#{Path.join(dir, "answer")}" ]; then exec "#{stereo_match_path()}" "$@"; fi
    exec cat > /dev/null
    """)

    File.chmod!(silent, 0o755)
    silent
  end

  @doc "A `u8` `{height, width}` image of random noise, the same for the same `seed`."
  @spec texture(pos_integer(), pos_integer(), integer()) :: Nx.Tensor.t()
  def texture(height, width, seed) do
    {noise, _key} =
      Nx.Random.randint(Nx.Random.key(seed), 0, 256, shape: {height, width}, type: :s32)

    Nx.as_type(noise, :u8)
  end

  @doc "The camera frame of the `u8` `image`, as a grey frame."
  @spec frame(Nx.Tensor.t()) :: Frame.t()
  def frame(image) do
    {height, width} = Nx.shape(image)
    %Frame{label: "left", grey: Nx.to_binary(image), width: width, height: height, capture_ns: 0}
  end

  @doc "The pair of the frames of the `left` and `right` images."
  @spec frames_pair(Nx.Tensor.t(), Nx.Tensor.t()) :: Pair.t()
  def frames_pair(left, right), do: %Pair{left_frame: frame(left), right_frame: frame(right)}

  @doc """
  A pair without camera frames, for the stages that read tensors, with
  `fields`, a keyword list or map of `VisionCore.Stereo.Pair` fields, set.
  """
  @spec pair(keyword() | map()) :: Pair.t()
  def pair(fields),
    do: struct!(Pair, Map.merge(%{left_frame: nil, right_frame: nil}, Map.new(fields)))

  @doc """
  The members (`%{module:, name:, state:}`) of `stages`, each initialised
  for `context` and named after its module.
  """
  @spec members([stage()], Stage.context()) :: [map()]
  def members(stages, context) do
    for stage <- stages do
      {module, opts} = stage_spec(stage)
      {:ok, state} = module.init(opts, context)
      %{module: module, name: module, state: state}
    end
  end

  defp stage_spec({module, opts}), do: {module, opts}
  defp stage_spec(module) when is_atom(module), do: {module, []}

  @doc "The `VisionCore.Stereo.NxSegment` of `stages`, compiled with `compiler`."
  @spec nx_segment([stage()], Stage.context(), module()) :: NxSegment.t()
  def nx_segment(stages, context, compiler \\ EXLA) do
    {:ok, segment} =
      NxSegment.build(members(stages, context), context, defn_options: [compiler: compiler])

    segment
  end

  @doc """
  The `VisionCore.Stereo.NativeSegment` of `stages`, sending its pairs to
  `matcher`: the application's `VisionCore.Stereo.Matcher` by default,
  which the test starts.
  """
  @spec native_segment([stage()], Stage.context(), GenServer.server()) :: NativeSegment.t()
  def native_segment(stages, context, matcher \\ Matcher) do
    {:ok, segment} = NativeSegment.build(members(stages, context), context, matcher: matcher)
    segment
  end

  @doc """
  Runs `input` through `segment`, of either backend, with the segment's
  context as the pair's geometry, as the pipeline does: the pair it
  fills, and the segment, which carries what its stages keep to the next
  pair.
  """
  @spec run_segment(Segment.t(), input()) :: {Pair.t(), Segment.t()}
  def run_segment(segment, input) do
    {backend, context} = backend(segment)
    pair = %{to_pair(input) | geometry: context}
    {:ok, pair, segment} = Segment.run(backend, pair, segment, :infinity)
    {pair, segment}
  end

  defp backend(%NxStereo.NxSegment{geometry: context}), do: {NxSegment, context}
  defp backend(%NxStereo.NativeSegment{geometry: context}), do: {NativeSegment, context}

  @doc """
  Runs `inputs`, in order, through one `VisionCore.Stereo.NxSegment` of
  `stages`, so what the stages carry flows from pair to pair: the pairs
  they fill.
  """
  @spec run_nx([stage()], Stage.context(), [input()], module()) :: [Pair.t()]
  def run_nx(stages, context, inputs, compiler \\ EXLA),
    do: run_inputs(nx_segment(stages, context, compiler), inputs)

  @doc """
  Runs `inputs`, in order, through one `VisionCore.Stereo.NativeSegment`
  of `stages` on `matcher` (see `native_segment/3`): the pairs they fill.
  """
  @spec run_native([stage()], Stage.context(), [input()], GenServer.server()) :: [Pair.t()]
  def run_native(stages, context, inputs, matcher \\ Matcher),
    do: run_inputs(native_segment(stages, context, matcher), inputs)

  defp run_inputs(segment, inputs) do
    {pairs, _segment} = Enum.map_reduce(inputs, segment, &run_segment(&2, &1))
    pairs
  end

  @doc """
  Runs the stage `module`, started with `stage_opts`, alone on `input`
  through a segment of its own: the pair it fills.

  Options:

    * `:backend` (`:nx`) — `:nx`, or `:native` on a
      `VisionCore.Stereo.Matcher` started for the run, which raises an
      `ArgumentError` for a stage that declares no native kind.
    * `:compiler` (`EXLA`) — what the `:nx` backend compiles with.
  """
  @spec run_stage(module(), keyword(), Stage.context(), input(), keyword()) :: Pair.t()
  def run_stage(module, stage_opts, context, input, run_opts \\ []) do
    run_opts = Keyword.validate!(run_opts, backend: :nx, compiler: EXLA)
    stages = [{module, stage_opts}]

    [filled] =
      case run_opts[:backend] do
        :nx -> run_nx(stages, context, [input], run_opts[:compiler])
        :native -> run_native(stages, context, [input], start_matcher(module))
      end

    filled
  end

  @doc """
  What `run_stage/5` returns for each backend that runs the stage `module`,
  by backend: `:nx`, and `:native` when it declares a native kind. Takes
  the `:compiler` option.
  """
  @spec run_stage_on_each_backend(module(), keyword(), Stage.context(), input(), keyword()) ::
          %{required(:nx) => Pair.t(), optional(:native) => Pair.t()}
  def run_stage_on_each_backend(module, stage_opts, context, input, run_opts \\ []) do
    backends = if NxStage.native_kind(module), do: [:nx, :native], else: [:nx]

    Map.new(backends, fn backend ->
      run_opts = Keyword.put(run_opts, :backend, backend)
      {backend, run_stage(module, stage_opts, context, input, run_opts)}
    end)
  end

  defp to_pair(%Pair{} = pair), do: pair
  defp to_pair(fields), do: pair(fields)

  defp start_matcher(module) do
    case NxStage.native_kind(module) do
      nil ->
        raise ArgumentError, "#{inspect(module)} declares no native kind"

      _kind ->
        ExUnit.Callbacks.start_supervised!(
          {Matcher, name: nil, path: stereo_match_path()},
          id: make_ref()
        )
    end
  end
end
