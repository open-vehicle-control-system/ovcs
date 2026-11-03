defmodule VisionCore.Stereo.Supervisor do
  @moduledoc """
  Self-contained supervisor for one stereo unit. Owns:

    1. Two camera drivers (left + right) of the same `VisionCore.Camera`
       implementation.
    2. `VisionCore.Stereo.Pipeline`, which turns a pair of frames into
       disparity and depth through its stages.
    3. `VisionCore.Stereo.Pairer`, which pairs the drivers' frames and
       feeds the pipeline.
    4. With `:align_correction`, `VisionCore.Stereo.AlignmentCorrection`,
       before the parameters that declare its switch.
    5. `VisionCore.Stereo.Parameters`, which declares the unit's
       parameter groups in `VisionCore.Parameters`.
    6. A `VisionCore.Ros2.Services.SetCameraInfoServer` per side with a
       calibration path, for `cameracalibrator`'s commit.

  The unit publishes nothing itself: `VisionCore.Ros2.Exporter` takes
  its frames and pairs to ROS 2, outside the unit, under the exporters
  (`VisionCore.Exporters`), with the `:publish_*` and
  `:raw_image_max_hz` options below.

  The children subscribe to the drivers' frames and the pipeline's pairs
  through `VisionCore.Outputs`, which holds a subscription across the
  producer's restarts. Children start in that order and the strategy is
  `:rest_for_one` because the children after a driver or the pipeline
  hold state about it: the pairer waits for the pipeline's
  `:stereo_pipeline_ready`, and `VisionCore.Stereo.Parameters` applies
  the parameters' values when it declares its groups, at start. Drivers
  stop deliberately when their subprocess exits, so restarts are a
  designed path.

  The unit has its own restart budget, and `VisionCore.Components`
  starts it as a `:transient` child: a camera that keeps failing
  exhausts this budget, the unit shuts down and stays down, and the
  rest of the vision core keeps running, with `VisionCore.Status`
  reporting the cameras absent. A unit that fails to start, such as
  one whose camera exits while the children after it start, is left
  down the same way.

  ## Required opts

    * `:driver` — module implementing `VisionCore.Camera`.
      Same module for both sides; each side gets a separate
      GenServer instance addressed via the per-side opts.
    * `:left`, `:right` — keyword lists of per-side opts. Must
      contain the driver-specific addressing
      (`:device` for v4l2/gstreamer, `:camera_id` for libcamera).
      Optionally `:frame_id`, `:calibration_path` (override the
      defaults derived from `:topic_prefix` and `:calibration_dir`).

  ## Optional opts (sensible defaults)

    * `:width` (1280), `:height` (720), `:fps` (30) — applied to
      both camera drivers.
    * `:match_width`, `:match_height` (`:width`, `:height`) — the size
      the pipeline matches at, and so the size of the disparity, depth
      and point cloud. Smaller than the capture size, the frames are
      shrunk to it while they are rectified; larger, the pipeline does
      not start.
    * `:publish_disparity_image` (`false`), `:publish_rectified_image`
      (`false`), `:publish_raw_images` (`true`), `:raw_image_max_hz` (10)
      — what `VisionCore.Ros2.Exporter` publishes of the unit, besides
      the disparity, depth and point cloud; see
      `VisionCore.Ros2.Exporter.Stereo`.
    * `:topic_prefix` (`"stereo"`) — root of every topic the unit is
      published under, and of its parameters and calibration files.
      Also drives the default `frame_id` for each side
      (`<prefix>_left`, `<prefix>_right`).
    * `:calibration_dir` — when set, the per-side
      `calibration_path` defaults to
      `<calibration_dir>/<topic_prefix>_<side>.yaml`.
    * `:calibration_store_dir` — a writable directory for
      calibrations committed at runtime (`cameracalibrator`'s
      COMMIT), as `<topic_prefix>_<side>.yaml`. When both sides are
      stored there they take precedence over `calibration_path`, so
      a calibration survives a restart on a read-only root
      filesystem. Without it, COMMIT writes to `calibration_path`.
    * `:pair_tolerance_ms` (33) — see `VisionCore.Stereo.Pairer`.
    * `:align_correction` (`true`) — keep the rectified rows lined up
      with `VisionCore.Stereo.AlignmentCorrection`.
    * `:stages` (`VisionCore.Stereo.Pipeline.default_stages/0`) — the
      pipeline's stages. The calibration paths and the capture size come
      from the options above, the matching size from `:match_width` and
      `:match_height`. Two stages that declare `right_row_offset`, or
      that provide `:alignment`, are refused
      (`VisionCore.Stereo.AlignmentCorrection.check_stages!/1`).
    * `:compute` (`:nx`) — `:native` computes every stage that has a
      native implementation in the `stereo_match` Port, for a CPU; see
      `VisionCore.Stereo.Pipeline`.
    * `:backends` (`VisionCore.Stereo.NativeSegment` on
      `VisionCore.Stereo.Matcher`, then `VisionCore.Stereo.NxSegment`
      with `:defn_options`) — the pipeline's backends, each
      `{module, opts}`.
    * `:defn_options` (`config :vision_core, :nx_defn_options`, else
      EXLA where it is loaded, as on a workstation, else Nx's evaluator) —
      how the default backends' NxSegment compiles Nx stages; refused
      beside `:backends`, among whose options NxSegment's go
      (`VisionCore.Stereo.Pipeline.check_backend_options!/1`).
  """
  use Supervisor
  require Logger

  alias VisionCore.Ros2.Services.SetCameraInfoServer

  alias VisionCore.Stereo.{
    AlignmentCorrection,
    Matcher,
    NativeSegment,
    NxSegment,
    Pairer,
    Parameters,
    Pipeline
  }

  @default_width 1280
  @default_height 720
  @default_fps 30
  @default_topic_prefix "stereo"
  @default_pair_tolerance_ms 33
  @max_restarts 10
  @max_seconds 60

  @doc """
  Starts the stereo unit; see the module doc for `opts`. `:ignore` when
  it fails to start, so the vision core starts without it.
  """
  def start_link(opts) do
    case Supervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, reason} ->
        Logger.error("#{__MODULE__} failed to start, cameras down: #{inspect(reason)}")
        :ignore

      started ->
        started
    end
  end

  @impl Supervisor
  def init(opts) do
    config = build_config(opts)
    log_stored_calibration(config)

    Supervisor.init(child_specs(config),
      strategy: :rest_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end

  @doc """
  The camera drivers of the stereo unit in `config`, the active
  `VisionCore.Config`: `{driver, name}` for the left camera, then the
  right one, the driver module loaded so that `function_exported?/3`
  sees its functions. `[]` without a `:stereo` component.
  """
  @spec cameras(VisionCore.Config.t()) :: [{module(), atom()}]
  def cameras(%VisionCore.Config{components: components}) do
    case Enum.find_value(components, &stereo_options/1) do
      nil ->
        []

      opts ->
        driver = Keyword.fetch!(opts, :driver)
        Code.ensure_loaded(driver)
        for label <- ["left", "right"], do: {driver, driver.name_for(label)}
    end
  end

  defp stereo_options({:stereo, opts}), do: opts
  defp stereo_options(_component), do: nil

  @doc """
  The outputs of the stereo unit in `config`, each with its
  `VisionCore.Outputs` key: its pipeline's pairs, then its left and
  right cameras' frames, as `VisionCore.Exporter` names them. `[]`
  without a `:stereo` component.
  """
  @spec outputs(VisionCore.Config.t()) :: [
          {VisionCore.Exporter.output(), VisionCore.Outputs.key()}
        ]
  def outputs(config) do
    case cameras(config) do
      [] ->
        []

      [{_left_driver, left}, {_right_driver, right}] ->
        [
          {:stereo_pair, {:stereo_pair, Pipeline}},
          {{:camera_frame, :left}, {:camera_frame, left}},
          {{:camera_frame, :right}, {:camera_frame, right}}
        ]
    end
  end

  @doc """
  The `VisionCore.Stereo.Pipeline` options the stereo unit starts with
  for `opts`, the `:stereo` component's options: what
  `mix vision_core.nx_cache` compiles for.
  """
  @spec pipeline_options(keyword()) :: keyword()
  def pipeline_options(opts) do
    {Pipeline, pipeline_opts} = opts |> build_config() |> pipeline_spec()
    pipeline_opts
  end

  @doc """
  The cameras of the stereo unit `opts`, the `:stereo` component's
  options, describe: the driver, the topic prefix, the capture size and
  rate, and each side's options with its frame id and calibration path
  resolved as the unit resolves them, a stored calibration first
  (`use_stored_calibration/4`). Unlike the unit's start, it checks
  neither the stages nor the backends.
  """
  @spec camera_options(keyword()) :: keyword()
  def camera_options(opts) do
    topic_prefix = Keyword.get(opts, :topic_prefix, @default_topic_prefix)

    {left, right} =
      sides(Keyword.get(opts, :left, []), Keyword.get(opts, :right, []), opts, topic_prefix)

    [
      driver: Keyword.get(opts, :driver),
      topic_prefix: topic_prefix,
      width: Keyword.get(opts, :width, @default_width),
      height: Keyword.get(opts, :height, @default_height),
      fps: Keyword.get(opts, :fps, @default_fps),
      left: left,
      right: right
    ]
  end

  defp build_config(opts) do
    topic_prefix = Keyword.get(opts, :topic_prefix, @default_topic_prefix)

    {left, right} =
      sides(Keyword.fetch!(opts, :left), Keyword.fetch!(opts, :right), opts, topic_prefix)

    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)
    stages = Keyword.get_lazy(opts, :stages, &Pipeline.default_stages/0)
    :ok = AlignmentCorrection.check_stages!(stages)

    %{
      driver: Keyword.fetch!(opts, :driver),
      width: width,
      height: height,
      match_width: Keyword.get(opts, :match_width, width),
      match_height: Keyword.get(opts, :match_height, height),
      fps: Keyword.get(opts, :fps, @default_fps),
      topic_prefix: topic_prefix,
      pair_tolerance_ms: Keyword.get(opts, :pair_tolerance_ms, @default_pair_tolerance_ms),
      align_correction: Keyword.get(opts, :align_correction, true),
      stages: stages,
      backends: backends(opts),
      compute: Keyword.get(opts, :compute, :nx),
      left: left,
      right: right
    }
  end

  defp backends(opts) do
    Pipeline.check_backend_options!(opts)

    Keyword.get(opts, :backends) ||
      [
        {NativeSegment, matcher: Matcher},
        {NxSegment, defn_options: Keyword.get(opts, :defn_options) || default_defn_options()}
      ]
  end

  defp default_defn_options do
    cond do
      options = Application.get_env(:vision_core, :nx_defn_options) -> options
      Code.ensure_loaded?(EXLA) -> [compiler: EXLA]
      true -> []
    end
  end

  defp sides(left, right, opts, topic_prefix) do
    calibration_dir = Keyword.get(opts, :calibration_dir)

    use_stored_calibration(
      resolve_side_opts(left, :left, topic_prefix, calibration_dir),
      resolve_side_opts(right, :right, topic_prefix, calibration_dir),
      Keyword.get(opts, :calibration_store_dir),
      topic_prefix
    )
  end

  defp log_stored_calibration(%{left: left}) do
    store_path = left[:calibration_store_path]

    if store_path && left[:calibration_path] == store_path,
      do: Logger.info("#{__MODULE__} using the calibration stored in #{Path.dirname(store_path)}")
  end

  defp resolve_side_opts(side_opts, side, topic_prefix, calibration_dir) do
    side_string = Atom.to_string(side)

    side_opts
    |> Keyword.put_new(:frame_id, "#{topic_prefix}_#{side_string}")
    |> Keyword.put_new_lazy(:calibration_path, fn ->
      default_calibration_path(calibration_dir, topic_prefix, side_string)
    end)
  end

  @doc """
  The per-side opts with `:calibration_store_path` set from
  `store_directory`, and `:calibration_path` pointing at the stored files
  when both sides are stored: one stored side alone would pair two
  calibrations solved apart. Unchanged when `store_directory` is `nil`.
  """
  def use_stored_calibration(left, right, nil, _topic_prefix), do: {left, right}

  def use_stored_calibration(left, right, store_directory, topic_prefix) do
    left_store = Path.join(store_directory, "#{topic_prefix}_left.yaml")
    right_store = Path.join(store_directory, "#{topic_prefix}_right.yaml")
    left = Keyword.put(left, :calibration_store_path, left_store)
    right = Keyword.put(right, :calibration_store_path, right_store)

    if File.exists?(left_store) and File.exists?(right_store) do
      {Keyword.put(left, :calibration_path, left_store),
       Keyword.put(right, :calibration_path, right_store)}
    else
      {left, right}
    end
  end

  @doc """
  Reloads the pipeline's calibration, has `VisionCore.Ros2.Exporter` read
  the raw camera info it publishes again, and starts the row correction
  (`VisionCore.Stereo.AlignmentCorrection`) over: a new calibration lines
  the rows up itself, so the `right_row_offset` of the stage that
  declares it (`VisionCore.Stereo.AlignmentCorrection.offset_stage/1`)
  returns to 0 and its saved value under `prefix` is forgotten.
  """
  def reload_calibration(pipeline, prefix, paths \\ []) do
    with :ok <- Pipeline.reload_calibration(pipeline, paths) do
      :ok = VisionCore.Ros2.Exporter.reload_calibration(paths)

      case pipeline |> Pipeline.stage_options() |> AlignmentCorrection.offset_stage() do
        nil ->
          :ok

        %{stage: stage} ->
          {:ok, _values} = Pipeline.set_options(pipeline, stage, right_row_offset: 0.0)
          forget_parameter("#{prefix}.#{stage}.right_row_offset")
      end

      :ok
    end
  end

  defp forget_parameter(id) do
    if Process.whereis(VisionCore.Parameters), do: VisionCore.Parameters.forget(id)
  end

  @doc """
  Reloads the pipeline from the stored calibration once both sides
  are stored, as `reload_calibration/3`. COMMIT stores one side at a
  time.
  """
  def reload_stored_calibration(pipeline, prefix, left_store, right_store) do
    if File.exists?(left_store) and File.exists?(right_store) do
      reload_calibration(pipeline, prefix,
        left_calibration_path: left_store,
        right_calibration_path: right_store
      )
    else
      :ok
    end
  end

  defp default_calibration_path(nil, _topic_prefix, _side), do: nil

  defp default_calibration_path(calibration_dir, topic_prefix, side) do
    Path.join(calibration_dir, "#{topic_prefix}_#{side}.yaml")
  end

  defp child_specs(config) do
    [
      camera_driver_spec(config, :left),
      camera_driver_spec(config, :right),
      pipeline_spec(config),
      {Pairer,
       cameras: [{config.driver, "left"}, {config.driver, "right"}],
       pair_tolerance_ms: config.pair_tolerance_ms}
    ] ++
      alignment_correction_specs(config) ++
      [
        Supervisor.child_spec(
          {Parameters,
           topic_prefix: config.topic_prefix,
           driver: config.driver,
           left: config.left,
           right: config.right,
           width: config.width,
           height: config.height,
           fps: config.fps,
           match_width: config.match_width,
           match_height: config.match_height},
          id: {:stereo, :parameters}
        )
      ] ++ set_camera_info_specs(config)
  end

  # Before the parameters, which declare its switch.
  defp alignment_correction_specs(%{align_correction: true}), do: [AlignmentCorrection]
  defp alignment_correction_specs(_config), do: []

  # `cameracalibrator`'s COMMIT persists the calibration and hot-reloads the pipeline.
  defp set_camera_info_specs(config) do
    Enum.flat_map([:left, :right], fn side ->
      side_opts = Map.fetch!(config, side)
      service_name = "#{config.topic_prefix}/#{side}/set_camera_info"

      case Keyword.get(side_opts, :calibration_store_path, side_opts[:calibration_path]) do
        nil ->
          []

        path ->
          [
            Supervisor.child_spec(
              {SetCameraInfoServer,
               service_name: service_name,
               calibration_path: path,
               camera_name: "#{config.topic_prefix}_#{side}",
               reload: reload_callback(config)},
              id: {:stereo, :set_camera_info, side}
            )
          ]
      end
    end)
  end

  defp reload_callback(config) do
    case {config.left[:calibration_store_path], config.right[:calibration_store_path]} do
      {nil, nil} ->
        {__MODULE__, :reload_calibration, [Pipeline, config.topic_prefix]}

      {left_store, right_store} ->
        {__MODULE__, :reload_stored_calibration,
         [Pipeline, config.topic_prefix, left_store, right_store]}
    end
  end

  defp camera_driver_spec(config, side) do
    label = Atom.to_string(side)
    side_opts = Map.fetch!(config, side)

    driver_opts =
      side_opts
      |> Keyword.put(:label, label)
      |> Keyword.put_new(:width, config.width)
      |> Keyword.put_new(:height, config.height)
      |> Keyword.put_new(:fps, config.fps)
      # Not the driver's: the calibration is the pipeline's, the frame ids the exporter's.
      |> Keyword.delete(:calibration_path)
      |> Keyword.delete(:calibration_store_path)
      |> Keyword.delete(:frame_id)

    Supervisor.child_spec({config.driver, driver_opts}, id: {:stereo, :driver, side})
  end

  defp pipeline_spec(config) do
    {Pipeline,
     stages: config.stages,
     left_calibration_path: config.left[:calibration_path],
     right_calibration_path: config.right[:calibration_path],
     width: config.match_width,
     height: config.match_height,
     frame_width: config.width,
     frame_height: config.height,
     compute: config.compute,
     backends: config.backends}
  end
end
