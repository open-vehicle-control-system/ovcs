defmodule VisionCore.Stereo.Bench do
  @moduledoc """
  Times a pipeline's Nx segment on a board's GPU and checks its results
  against the same stages on EXLA, the way `mix vision_core.board_bench`
  runs it.

  `prepare/2` runs on your workstation: it compiles the default stages
  for the board into a module cache, unless they are to be computed
  natively, makes a textured pair of frames, and
  records EXLA's outputs for it. `run/1` runs on the board, from the
  directory `prepare/2` wrote: it runs the pair through the cached
  modules, compares each output with EXLA's, and times successive pairs,
  the pipeline's per-pair cost without the cameras.
  """

  alias VisionCore.Camera.Frame
  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.{NativeSegment, NxSegment, Pair, Pipeline, Segment}

  @boards %{"ventuno_q" => :ventuno_q_defn_options, "c100" => :c100_defn_options}
  @outputs [:left, :right, :disparity, :depth, :cloud, :sharpness, :alignment, :metrics]

  @doc """
  Writes into `dir` what `run/1` needs: the calibration, the module cache
  for `:board` (`"ventuno_q"` or `"c100"`), the frames and EXLA's outputs.

  ## Options

    * `:board` - required.
    * `:size` - the working `{width, height}`, required.
    * `:frame_size` - the frames' `{width, height}`; the working size by
      default.
    * `:disparity` - the Disparity stage's options.
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
    settings = Keyword.take(opts, [:board, :size, :frame_size, :disparity, :pairs, :compute])
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

    frames = frames(frame_width, frame_height, Keyword.get(opts, :disparity, []))
    {:ok, segment} = NxSegment.build(members, context, defn_options: [compiler: EXLA])
    {:ok, reference, _segment} = Segment.run(NxSegment, pair(frames, context), segment, :infinity)
    term = %{settings: settings, frames: frames, reference: outputs(reference)}
    File.write!(Path.join(dir, "bench.term"), :erlang.term_to_binary(term))
  end

  @doc """
  Runs the benchmark `prepare/2` wrote into `dir` and returns its report:
  how each output differs from EXLA's, then the time of each pair.
  """
  @spec run(Path.t()) :: String.t()
  def run(dir) do
    %{settings: settings, frames: frames, reference: reference} =
      dir |> Path.join("bench.term") |> File.read!() |> :erlang.binary_to_term()

    context = context(dir, settings)
    {backend, segment} = segment(settings, context, Path.join(dir, "cache"))
    {:ok, result, segment} = Segment.run(backend, pair(frames, context), segment, :infinity)

    {times, _segment} =
      Enum.map_reduce(1..Keyword.get(settings, :pairs, 10), segment, fn _, segment ->
        started = System.monotonic_time(:microsecond)
        {:ok, _, segment} = Segment.run(backend, pair(frames, context), segment, :infinity)
        {System.monotonic_time(:microsecond) - started, segment}
      end)

    differences =
      for {key, want} <- reference, do: "#{key}: #{compare(outputs(result)[key], want)}"

    median = times |> Enum.sort() |> Enum.at(div(length(times), 2))
    Enum.join(differences ++ ["us per pair: #{inspect(times)}, median #{median}"], "\n")
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
    for {module, opts} <-
          Pipeline.default_stages(disparity: Keyword.get(settings, :disparity, [])) do
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
    for key <- @outputs, value = Map.get(pair, key), value != nil, into: %{} do
      value =
        case {key, value} do
          {:depth, binary} -> Nx.from_binary(binary, :u16)
          {:cloud, binary} -> Nx.from_binary(binary, :f32)
          {_key, %Nx.Tensor{} = tensor} -> Nx.backend_copy(tensor, Nx.BinaryBackend)
          {_key, other} -> other
        end

      {key, value}
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
