defmodule VisionCore.Stereo.Supervisor do
  @moduledoc """
  Self-contained supervisor for one stereo unit. Owns:

    1. Two camera drivers (left + right) of the same `VisionCore.Camera`
       implementation, each given its side's frame id, which its frames
       carry.
    2. `VisionCore.Stereo.Pipeline`, which turns a pair of frames into
       disparity and depth through its stages.
    3. `VisionCore.Stereo.Pairer`, which pairs the drivers' frames and
       feeds the pipeline, and measures how far apart the cameras
       capture (`VisionCore.Stereo.Pairer.sync/1`).
    4. With `:align_correction`, `VisionCore.Stereo.AlignmentCorrection`,
       before the parameters that declare its switch.
    5. `VisionCore.Stereo.Parameters`, which declares the unit's
       parameter groups in `VisionCore.Parameters`.

  A unit with neither side's calibration file (`calibrated?/1`) is
  uncalibrated: it starts the two drivers and the parameters of the
  cameras alone, so that the cameras can be set and calibrated, and logs
  so. `VisionCore.Stereo.Calibration` restarts it
  once both files are written. With one side's file alone, the pipeline
  refuses to start, and so does the unit.

  The unit exports nothing itself: the exporters
  (`VisionCore.Exporters`), outside the unit, read its frames and pairs,
  each frame and pair carrying the cameras' frame ids, and
  `camera_options/1` for what else they need of its cameras.

  The children subscribe to the drivers' frames and the pipeline's pairs
  through `VisionCore.Outputs`, which holds a subscription across the
  producer's restarts. Children start in that order and the strategy is
  `:rest_for_one` because the children after a driver or the pipeline
  hold state about it: the pairer waits for the pipeline's
  `:stereo_pipeline_ready`, and `VisionCore.Stereo.Parameters` applies
  the parameters' values when it declares its groups, at start. A
  driver whose capture program exits or stalls stays up and starts it
  again (`VisionCore.Camera.Reopen`), so a camera that drops out costs
  the unit no restart; `VisionCore.Status` reports it absent meanwhile.

  The unit has its own restart budget, and `VisionCore.Components`
  starts it as a `:transient` child: children that keep crashing
  exhaust this budget and the unit shuts down, while the rest of the
  vision core keeps running, with `VisionCore.Status` reporting the
  cameras absent. A unit that fails to start, such as one given an
  option it does not take, is left down the same way, with the reason
  logged. `VisionCore.Reviver` starts a unit that is down again, once a
  minute. The refusal of an option the ROS 2 exporter takes
  names where it belongs: its `stereo:` publishes the images
  (`VisionCore.Ros2.Exporter`).

  ## Required opts

    * `:driver` — module implementing `VisionCore.Camera`.
      Same module for both sides; each side gets a separate
      GenServer instance addressed via the per-side opts.
    * `:left`, `:right` — keyword lists of per-side opts. Must
      contain the driver-specific addressing (`:device` for GStreamer,
      `:camera_id` for libcamera, `:csiphy` for `VisionCore.Camera.V4L2Pair`
      on a CAMSS board). Optionally `:frame_id`, the camera's optical
      frame, and `:calibration_path` (override the defaults derived from
      `:prefix` and `:calibration_dir`). A driver that captures both
      cameras together (`c:VisionCore.Camera.pair_options/0`) takes only
      its side options there, and its settings for both cameras beside
      `:width`.

  ## Optional opts (sensible defaults)

    * `:width` (1280), `:height` (720), `:fps` (30) — applied to
      both camera drivers; `:fps` is an integer from 1 on.
    * the pair options of a driver that captures both cameras together
      (`c:VisionCore.Camera.pair_options/0`), given once for both.
    * `:match_width`, `:match_height` (`:width`, `:height`) — the size
      the pipeline matches at, and so the size of the disparity, depth
      and point cloud. Smaller than the capture size, the frames are
      shrunk to it while they are rectified; larger, the pipeline does
      not start.
    * `:prefix` (`"stereo"`) — the unit's prefix: of its parameters
      (`<prefix>.<stage>.<setting>`), of its calibration files and of
      each side's default `frame_id` (`<prefix>_left`,
      `<prefix>_right`).
    * `:calibration_dir` — when set, the per-side
      `calibration_path` defaults to
      `<calibration_dir>/<prefix>_<side>.yaml`.
    * `:calibration_store_dir` — a writable directory for
      calibrations committed at runtime (from the dashboard, or
      `cameracalibrator`'s COMMIT through the ROS 2 exporter; see
      `VisionCore.Stereo.Calibration`), as `<prefix>_<side>.yaml`.
      When both sides are stored there they take precedence over
      `calibration_path`, so a calibration survives a restart on a
      read-only root filesystem. Without it, a commit writes to
      `calibration_path`.
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
  @default_prefix "stereo"
  @default_pair_tolerance_ms 33
  @max_restarts 10
  @max_seconds 60

  @options [:driver, :left, :right, :width, :height, :fps, :match_width, :match_height] ++
             [:prefix, :calibration_dir, :calibration_store_dir, :pair_tolerance_ms] ++
             [:align_correction, :stages, :compute, :backends, :defn_options]
  @side_options [:frame_id, :calibration_path]
  @exporter_options [
    :publish_disparity_image,
    :publish_rectified_image,
    :publish_raw_images,
    :raw_image_max_hz
  ]

  @doc """
  Starts the stereo unit; see the module doc for `opts`. `:ignore` when
  it fails to start, so the vision core starts without it.
  """
  def start_link(opts),
    do: VisionCore.Unit.start_contained(__MODULE__, opts, [name: __MODULE__], "cameras")

  @impl Supervisor
  def init(opts) do
    config = build_config(opts)
    log_stored_calibration(config)
    log_uncalibrated(config)

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
  sees its functions. `[]` without a `:stereo` component, or with one
  whose `:driver` is not a `VisionCore.Camera`.
  """
  @spec cameras(VisionCore.Config.t()) :: [{module(), atom()}]
  def cameras(%VisionCore.Config{components: components}) do
    with opts when is_list(opts) <- Enum.find_value(components, &stereo_options/1),
         driver = Keyword.get(opts, :driver),
         true <- camera_driver?(driver) do
      for label <- ["left", "right"], do: {driver, driver.name_for(label)}
    else
      _no_cameras -> []
    end
  end

  defp stereo_options({:stereo, opts}), do: opts
  defp stereo_options(_component), do: nil

  defp camera_driver?(driver),
    do:
      is_atom(driver) and Code.ensure_loaded?(driver) and function_exported?(driver, :name_for, 1)

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
  Whether both sides of the stereo unit in `config`, the active
  `VisionCore.Config`, have a calibration file where the unit resolves
  it (`camera_options/1`). `false` without a `:stereo` component, or with
  one whose cameras cannot be read.
  """
  @spec calibrated?(VisionCore.Config.t()) :: boolean()
  def calibrated?(config) do
    case camera_options(config) do
      {:ok, cameras} -> Enum.all?([cameras[:left], cameras[:right]], &calibration_file?/1)
      {:error, _reason} -> false
    end
  end

  defp calibration_file?(side_opts) do
    path = side_opts[:calibration_path]
    is_binary(path) and File.exists?(path)
  end

  defp uncalibrated?(config),
    do: not Enum.any?([config.left, config.right], &calibration_file?/1)

  defp log_uncalibrated(config) do
    if uncalibrated?(config) do
      missing =
        case for(side <- [config.left, config.right], path = side[:calibration_path], do: path) do
          [] -> "no calibration path"
          paths -> "no calibration at " <> Enum.join(paths, " nor ")
        end

      Logger.warning(
        "#{__MODULE__} uncalibrated, #{missing}: the cameras run without the depth pipeline"
      )
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
  The cameras of the stereo unit in `config`, the active
  `VisionCore.Config`, for the exporters that publish them: the driver,
  the unit's prefix, the capture size and rate, and each side's options
  with its frame id and calibration path resolved as the unit resolves
  them, a stored calibration first (`use_stored_calibration/4`), and its
  `:calibration_store_path` with a store. The store is read at each
  call. Unlike the unit's start, it checks neither the stages nor the
  backends. `{:error, reason}` without a `:stereo` component, or with one
  whose driver or sides cannot be read, or that has an option the unit
  does not take.
  """
  @spec camera_options(VisionCore.Config.t()) :: {:ok, keyword()} | {:error, String.t()}
  def camera_options(%VisionCore.Config{components: components}) do
    case Enum.find_value(components, &stereo_options/1) do
      nil -> {:error, "no :stereo component"}
      opts -> stereo_camera_options(opts)
    end
  end

  defp stereo_camera_options(opts) do
    with :ok <- check_keyword(opts, "the :stereo component's options"),
         driver = Keyword.get(opts, :driver),
         :ok <- check_options(opts, driver),
         :ok <- check_driver(driver),
         :ok <- check_keyword(Keyword.get(opts, :left), "its :left options"),
         :ok <- check_keyword(Keyword.get(opts, :right), "its :right options"),
         :ok <- check_sides(driver, Keyword.fetch!(opts, :left), Keyword.fetch!(opts, :right)),
         :ok <- check_fps(Keyword.get(opts, :fps, @default_fps)) do
      prefix = Keyword.get(opts, :prefix, @default_prefix)

      {left, right} =
        sides(Keyword.fetch!(opts, :left), Keyword.fetch!(opts, :right), opts, prefix)

      {:ok,
       [
         driver: driver,
         prefix: prefix,
         width: Keyword.get(opts, :width, @default_width),
         height: Keyword.get(opts, :height, @default_height),
         fps: Keyword.get(opts, :fps, @default_fps),
         left: left,
         right: right
       ]}
    end
  end

  defp check_fps(fps) when is_integer(fps) and fps > 0, do: :ok
  defp check_fps(fps), do: {:error, "its :fps is an integer from 1 on, got #{inspect(fps)}"}

  defp check_keyword(options, what) do
    if is_list(options) and Keyword.keyword?(options),
      do: :ok,
      else: {:error, "#{what}, #{inspect(options)}, are not a keyword list"}
  end

  defp check_options(opts, driver) do
    pair = Map.get(pair_options(driver) || %{}, :pair, [])

    case Enum.uniq(Keyword.keys(opts)) -- (@options ++ pair) do
      [] -> :ok
      refused -> {:error, Enum.map_join(refused, "; ", &refused_option/1)}
    end
  end

  defp pair_options(driver) do
    if camera_driver?(driver) and function_exported?(driver, :pair_options, 0),
      do: driver.pair_options()
  end

  defp check_sides(driver, left, right) do
    case pair_options(driver) do
      nil ->
        :ok

      %{pair: pair, side: side} ->
        taken = @side_options ++ side

        refused =
          for {name, options} <- [left: left, right: right],
              key <- Enum.uniq(Keyword.keys(options)),
              key not in taken,
              do: refused_side_option(name, key, pair, taken)

        if refused == [], do: :ok, else: {:error, Enum.join(refused, "; ")}
    end
  end

  defp refused_side_option(side, key, pair, taken) do
    if key in pair,
      do: "its #{inspect(side)} #{inspect(key)} is the pair's: give it beside :width",
      else: "its #{inspect(side)} has no option #{inspect(key)}; a side takes #{and_list(taken)}"
  end

  defp and_list(keys) do
    {others, [last]} = keys |> Enum.map(&inspect/1) |> Enum.split(-1)
    Enum.join(others, ", ") <> " and " <> last
  end

  defp refused_option(:topic_prefix), do: "its :topic_prefix is now :prefix"

  defp refused_option(option) when option in @exporter_options,
    do: "its #{inspect(option)} is the ROS 2 exporter's stereo: option (VisionCore.Ros2.Exporter)"

  defp refused_option(option), do: "it has no option #{inspect(option)}"

  defp check_driver(driver) do
    if camera_driver?(driver),
      do: :ok,
      else: {:error, "its :driver, #{inspect(driver)}, is not a VisionCore.Camera"}
  end

  # The cameras as the exporters read them (`camera_options/1`), with what only the unit uses.
  defp build_config(opts) do
    cameras =
      case stereo_camera_options(opts) do
        {:ok, cameras} -> Map.new(cameras)
        {:error, reason} -> raise ArgumentError, reason
      end

    stages = Keyword.get_lazy(opts, :stages, &Pipeline.default_stages/0)
    :ok = AlignmentCorrection.check_stages!(stages)

    Map.merge(cameras, %{
      pair: pair_settings(opts, cameras.driver),
      match_width: Keyword.get(opts, :match_width, cameras.width),
      match_height: Keyword.get(opts, :match_height, cameras.height),
      pair_tolerance_ms: Keyword.get(opts, :pair_tolerance_ms, @default_pair_tolerance_ms),
      align_correction: Keyword.get(opts, :align_correction, true),
      stages: stages,
      backends: backends(opts),
      compute: Keyword.get(opts, :compute, :nx)
    })
  end

  # The pair's options, for a driver that captures both cameras together; `nil` for another.
  defp pair_settings(opts, driver) do
    case pair_options(driver) do
      nil -> nil
      %{pair: pair} -> Keyword.take(opts, pair)
    end
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

  defp sides(left, right, opts, prefix) do
    calibration_dir = Keyword.get(opts, :calibration_dir)

    use_stored_calibration(
      resolve_side_opts(left, :left, prefix, calibration_dir),
      resolve_side_opts(right, :right, prefix, calibration_dir),
      Keyword.get(opts, :calibration_store_dir),
      prefix
    )
  end

  defp log_stored_calibration(%{left: left}) do
    store_path = left[:calibration_store_path]

    if store_path && left[:calibration_path] == store_path,
      do: Logger.info("#{__MODULE__} using the calibration stored in #{Path.dirname(store_path)}")
  end

  defp resolve_side_opts(side_opts, side, prefix, calibration_dir) do
    side_string = Atom.to_string(side)

    side_opts
    |> Keyword.put_new(:frame_id, "#{prefix}_#{side_string}")
    |> Keyword.put_new_lazy(:calibration_path, fn ->
      default_calibration_path(calibration_dir, prefix, side_string)
    end)
  end

  @doc """
  The per-side opts with `:calibration_store_path` set from
  `store_directory`, and `:calibration_path` pointing at the stored files
  when both sides are stored: one stored side alone would pair two
  calibrations solved apart. Unchanged when `store_directory` is `nil`.
  """
  def use_stored_calibration(left, right, nil, _prefix), do: {left, right}

  def use_stored_calibration(left, right, store_directory, prefix) do
    left_store = Path.join(store_directory, "#{prefix}_left.yaml")
    right_store = Path.join(store_directory, "#{prefix}_right.yaml")
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
  Reloads the pipeline's calibration and starts the row correction
  (`VisionCore.Stereo.AlignmentCorrection`) over: a new calibration lines
  the rows up itself, so the `right_row_offset` of the stage that
  declares it (`VisionCore.Stereo.AlignmentCorrection.offset_stage/1`)
  returns to 0 and its saved value under `prefix` is forgotten.
  """
  def reload_calibration(pipeline, prefix, paths \\ []) do
    with :ok <- Pipeline.reload_calibration(pipeline, paths) do
      case pipeline |> Pipeline.stage_options() |> AlignmentCorrection.offset_stage() do
        nil ->
          :ok

        %{stage: stage} ->
          {:ok, _values} = Pipeline.set_options(pipeline, stage, right_row_offset: 0.0)
          forget_row_offset(prefix, stage)
      end

      :ok
    end
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

  @doc """
  Forgets the saved `right_row_offset` of the stage that declares it among
  the stages of the stereo unit in `config`, the active
  `VisionCore.Config`, as `reload_calibration/3` does: called before the
  unit restarts on a new calibration, so that the offset saved under the
  previous one is not applied as it starts. Nothing to forget without a
  `:stereo` component or such a stage.
  """
  @spec forget_row_offset(VisionCore.Config.t()) :: :ok
  def forget_row_offset(%VisionCore.Config{components: components}) do
    with opts when is_list(opts) <- Enum.find_value(components, &stereo_options/1),
         %{stage: stage} <-
           opts
           |> Keyword.get_lazy(:stages, &Pipeline.default_stages/0)
           |> Enum.flat_map(&stage_module/1)
           |> Enum.map(&%{stage: Pipeline.stage_name(&1), module: &1})
           |> AlignmentCorrection.offset_stage() do
      forget_row_offset(Keyword.get(opts, :prefix, @default_prefix), stage)
    end

    :ok
  end

  defp stage_module({module, _opts}) when is_atom(module), do: [module]
  defp stage_module(module) when is_atom(module), do: [module]
  defp stage_module(_stage), do: []

  # An offset the store keeps is applied at the next start, on a calibration it was not measured for.
  defp forget_row_offset(prefix, stage) do
    id = "#{prefix}.#{stage}.right_row_offset"

    with pid when is_pid(pid) <- Process.whereis(VisionCore.Parameters),
         {:error, reason} <- VisionCore.Parameters.forget(id) do
      Logger.error("#{__MODULE__} could not forget the saved #{id}: #{reason}")
    end
  end

  defp default_calibration_path(nil, _prefix, _side), do: nil

  defp default_calibration_path(calibration_dir, prefix, side) do
    Path.join(calibration_dir, "#{prefix}_#{side}.yaml")
  end

  defp child_specs(config) do
    drivers = [camera_driver_spec(config, :left), camera_driver_spec(config, :right)]

    if uncalibrated?(config),
      do: drivers ++ [parameters_spec(config, pipeline: nil)],
      else: drivers ++ pipeline_specs(config)
  end

  defp pipeline_specs(config) do
    [
      pipeline_spec(config),
      {Pairer,
       cameras: [{config.driver, "left"}, {config.driver, "right"}],
       pair_tolerance_ms: config.pair_tolerance_ms,
       fps: config.fps}
    ] ++
      alignment_correction_specs(config) ++
      [
        parameters_spec(config,
          match_width: config.match_width,
          match_height: config.match_height
        )
      ]
  end

  # `pipeline: nil` among `options` declares the cameras alone.
  defp parameters_spec(config, options) do
    Supervisor.child_spec(
      {Parameters,
       [
         prefix: config.prefix,
         driver: config.driver,
         left: config.left,
         right: config.right,
         width: config.width,
         height: config.height,
         fps: config.fps
       ] ++ options},
      id: {:stereo, :parameters}
    )
  end

  # Before the parameters, which declare its switch.
  defp alignment_correction_specs(%{align_correction: true}), do: [AlignmentCorrection]
  defp alignment_correction_specs(_config), do: []

  defp camera_driver_spec(config, side) do
    label = Atom.to_string(side)
    side_opts = Map.fetch!(config, side)

    driver_opts =
      side_opts
      |> Keyword.put(:label, label)
      |> Keyword.put_new(:width, config.width)
      |> Keyword.put_new(:height, config.height)
      |> Keyword.put_new(:fps, config.fps)
      |> without_calibration()

    Supervisor.child_spec({config.driver, driver_opts ++ pair_driver_options(config)},
      id: {:stereo, :driver, side}
    )
  end

  defp pair_driver_options(%{pair: nil}), do: []

  defp pair_driver_options(config),
    do:
      config.pair ++
        [left: without_calibration(config.left), right: without_calibration(config.right)]

  # Not the driver's: the calibration is the pipeline's.
  defp without_calibration(options),
    do: Keyword.drop(options, [:calibration_path, :calibration_store_path])

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
