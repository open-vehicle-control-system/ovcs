defmodule RosBridge.StereoCamera.OpenCV do
  @moduledoc """
  Classical stereo-depth backend backed by Evision's `StereoSGBM`
  (semi-global block matching). Works on host and target with the
  same code — the only difference is which camera driver feeds the
  frames. `Publishers.StereoCamera` and `StereoCamera.Supervisor`
  talk to this module by name.

  ## Pipeline (per submitted pair)

      decode_jpeg             # JPEG → single-channel Mat
        ↓
      rectify_image           # undistortion + rectification maps
        ↓
      apply_clahe             # local contrast equalisation (:clahe)
        ↓
      compute_disparity       # StereoSGBM → CV_16S, pixels × 16
        ↓
      post_filter_disparity   # median filter (:post_filter)
        ↓
      build_result            # disparity (px), depth (mm), decimated point cloud

  Every `:quality_every_n`-th pair is also measured for disparity
  quality, which is logged with the stage timings: the share of
  matched pixels, the mean and spread of their disparity, and the
  jitter, the mean frame-to-frame disparity change over pixels matched
  in both frames (algorithm noise on a static scene).

  The rectification LUT is computed once at init from each
  camera's calibration matrices (K, D, R, P) via
  `Evision.initUndistortRectifyMap/6`. At runtime it's a single
  `Evision.remap/4` per frame — cheap.

  Skipping rectification (e.g. for testing with pre-rectified
  fixtures) is supported via `rectify: false` in the opts.

  ## Required opts

    * `:left_calibration_path`, `:right_calibration_path` —
      paths to `camera_calibration_parsers`-format YAMLs. The
      right camera's projection matrix `P_right[0,3] = -fx × T`
      encodes the baseline.
    * `:width`, `:height` — the actual capture resolution. The
      backend scales the calibration matrices (K, P) from the
      YAML's `image_width` / `image_height` to this resolution
      before building rectification look-up tables, so the maps
      match what the camera is actually delivering.

  ## Optional opts

    * `:rectify` (default `true`) — apply per-side undistortion
      + rectification before SGBM. Set to `false` if the driver
      already produces rectified frames.
    * `:clahe` (`true`), `:clahe_clip_limit` (`2.0`),
      `:clahe_tile_grid_size` (`{8, 8}`) — local contrast
      equalisation before matching.
    * `:num_disparities` (64), `:block_size` (5), `:min_disparity`
      (0), `:mode` (`:sgbm_3way`; or `:sgbm`, `:hh`, `:hh4`) —
      `Evision.StereoSGBM` parameters.
    * `:uniqueness_ratio` (10), `:disp12_max_diff` (2),
      `:pre_filter_cap` (31), `:speckle_window_size` (100),
      `:speckle_range` (32), `:p1` / `:p2` (8 and 32 × `block_size`²)
      — the matcher's filtering and smoothness settings; see
      `option_specs/0`.
    * `:post_filter` (`:median` or `:none`), `:post_filter_ksize` (5)
      — filter applied to the raw disparity.
    * `:cloud_decimation` (4) — keep one point cloud point every N
      pixels in each direction; 0 publishes no point cloud. The full
      grid is 12 bytes a pixel, more than one Zenoh session drains
      next to the disparity and depth images.
    * `:quality_every_n` (5) — how often the quality probe runs.
    * `:name` — GenServer name (default `__MODULE__`).
  """
  use GenServer
  require Logger

  alias RosBridge.Camera.{Calibration, Frame}
  alias RosBridge.StereoCamera.{Result, Telemetry}

  # SGBM's native fixed-point: stored disparity = pixels × 16.
  @disparity_fixed_point_scale 16.0

  # Points outside this depth range carry no measurement.
  @min_point_depth_m 0.05
  @max_point_depth_m 20.0

  @doc "Starts the backend; see the module doc for `opts`."
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Sends every later `{:stereo_result, %Result{}}` to `listener` as a cast."
  def register_listener(server, listener),
    do: GenServer.cast(server, {:register_listener, listener})

  @doc "Queues one left/right frame pair for matching."
  def submit_pair(server, %Frame{} = left, %Frame{} = right),
    do: GenServer.cast(server, {:submit_pair, left, right})

  @doc """
  Change matching settings while running, from the next pair on:
  `:uniqueness_ratio`, `:speckle_window_size`, `:speckle_range`, `:p1`,
  `:p2`, `:disp12_max_diff`, `:pre_filter_cap`, `:num_disparities`
  (a multiple of 16), `:clahe` (boolean) and `:clahe_clip_limit`.
  Returns the settings now in force, or why the request was refused.
  """
  def set_options(server, options), do: GenServer.call(server, {:set_options, options})

  @doc "The matching settings in force."
  def options(server), do: GenServer.call(server, :options)

  @doc """
  Reload calibration + rectification maps from the side YAMLs
  currently on disk. Used after a `set_camera_info` service call
  rewrites them — lets the next disparity reflect the new
  geometry without restarting the bridge. `paths`
  (`:left_calibration_path`, `:right_calibration_path`) replaces
  the YAMLs to read, for this and later reloads, once they load.
  """
  def reload_calibration(server, paths \\ []) do
    GenServer.call(server, {:reload_calibration, paths})
  end

  @impl GenServer
  def init(opts) do
    left_calibration_raw =
      Calibration.load!(Keyword.fetch!(opts, :left_calibration_path))

    right_calibration_raw =
      Calibration.load!(Keyword.fetch!(opts, :right_calibration_path))

    # Scale K and P to the capture resolution, or `Evision.remap`
    # upsamples every frame back to the calibration's.
    actual_width = Keyword.fetch!(opts, :width)
    actual_height = Keyword.fetch!(opts, :height)

    left_calibration =
      Calibration.scale_to(left_calibration_raw, actual_width, actual_height)

    right_calibration =
      Calibration.scale_to(right_calibration_raw, actual_width, actual_height)

    {focal_length_px, baseline_m} = stereo_geometry(left_calibration, right_calibration)
    matcher = create_matcher(opts)

    # CLAHE gives SGBM's cost more signal in low-texture regions.
    clahe = if Keyword.get(opts, :clahe, true), do: create_clahe(opts)

    rectify? = Keyword.get(opts, :rectify, true)

    rectification_maps =
      if rectify? do
        %{
          left: build_rectification_maps(left_calibration),
          right: build_rectification_maps(right_calibration)
        }
      else
        nil
      end

    log_ready(focal_length_px, baseline_m, opts, rectify?, actual_width, actual_height)

    {:ok,
     %{
       listeners: [],
       matcher: matcher,
       focal_length_px: focal_length_px,
       baseline_m: baseline_m,
       principal_point: principal_point(left_calibration),
       cloud_decimation: Keyword.get(opts, :cloud_decimation, 4),
       num_disparities: Keyword.get(opts, :num_disparities, 64),
       block_size: Keyword.get(opts, :block_size, 5),
       min_disparity: Keyword.get(opts, :min_disparity, 0),
       rectification_maps: rectification_maps,
       rectify?: rectify?,
       clahe: clahe,
       post_filter: Keyword.get(opts, :post_filter, :median),
       post_filter_kernel_size: Keyword.get(opts, :post_filter_ksize, 5),
       previous_disparity: nil,
       frame_count: 0,
       quality_every_n: Keyword.get(opts, :quality_every_n, 5),
       telemetry: Telemetry.new(window: 30, label: "backend"),
       last_total_start_ns: nil,
       opts: opts
     }}
  end

  @impl GenServer
  def handle_call({:reload_calibration, paths}, _from, state) do
    opts = Keyword.merge(state.opts, paths)

    try do
      left_raw = Calibration.load!(Keyword.fetch!(opts, :left_calibration_path))
      right_raw = Calibration.load!(Keyword.fetch!(opts, :right_calibration_path))

      actual_width = Keyword.fetch!(opts, :width)
      actual_height = Keyword.fetch!(opts, :height)

      left_calibration = Calibration.scale_to(left_raw, actual_width, actual_height)
      right_calibration = Calibration.scale_to(right_raw, actual_width, actual_height)
      {focal_length_px, baseline_m} = stereo_geometry(left_calibration, right_calibration)

      rectification_maps =
        if state.rectify? do
          %{
            left: build_rectification_maps(left_calibration),
            right: build_rectification_maps(right_calibration)
          }
        else
          nil
        end

      Logger.info(
        "#{__MODULE__} reloaded calibration " <>
          "(fx=#{Float.round(focal_length_px, 2)} px, baseline=#{Float.round(baseline_m, 4)} m)"
      )

      {:reply, :ok,
       %{
         state
         | focal_length_px: focal_length_px,
           baseline_m: baseline_m,
           rectification_maps: rectification_maps,
           previous_disparity: nil,
           opts: opts
       }}
    rescue
      error ->
        Logger.warning("#{__MODULE__}: reload_calibration failed: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:set_options, options}, _from, state) do
    case validate_options(options) do
      :ok ->
        state = Enum.reduce(options, state, &apply_option/2)
        {:reply, {:ok, current_options(state)}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:options, _from, state), do: {:reply, current_options(state), state}

  @impl GenServer
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  def handle_cast({:submit_pair, %Frame{} = left, %Frame{} = right}, state) do
    total_start_ns = System.monotonic_time(:nanosecond)

    {result_or_error, state} = run_pipeline(left, right, state)

    case result_or_error do
      {:ok, %Result{} = result} ->
        Enum.each(state.listeners, &GenServer.cast(&1, {:stereo_result, result}))

      {:error, reason} ->
        Logger.warning("#{__MODULE__}: stereo pipeline failed: #{inspect(reason)}")
    end

    total_ns = System.monotonic_time(:nanosecond) - total_start_ns

    telemetry =
      state.telemetry
      |> Telemetry.record(:total, total_ns)
      |> Telemetry.record(:wall, elapsed_since(state.last_total_start_ns, total_start_ns))
      |> Telemetry.tick()

    {:noreply, %{state | telemetry: telemetry, last_total_start_ns: total_start_ns}}
  end

  defp elapsed_since(nil, _now_ns), do: 0
  defp elapsed_since(previous_ns, now_ns), do: now_ns - previous_ns

  defp run_pipeline(%Frame{} = left_frame, %Frame{} = right_frame, state) do
    {decode_ns, decoded} =
      timed(fn ->
        with {:ok, left} <- decode_jpeg(left_frame),
             {:ok, right} <- decode_jpeg(right_frame),
             do: {:ok, {left, right}}
      end)

    case decoded do
      {:ok, {left_image, right_image}} ->
        {rectify_ns, {left_rectified, right_rectified}} =
          timed(fn ->
            {
              rectify_image(left_image, state.rectification_maps, :left),
              rectify_image(right_image, state.rectification_maps, :right)
            }
          end)

        {clahe_ns, {left_equalized, right_equalized}} =
          timed(fn ->
            {apply_clahe(state.clahe, left_rectified), apply_clahe(state.clahe, right_rectified)}
          end)

        {sgbm_ns, raw_disparity_unfiltered} =
          timed(fn -> compute_disparity(state.matcher, left_equalized, right_equalized) end)

        {post_filter_ns, raw_disparity} =
          timed(fn -> post_filter_disparity(raw_disparity_unfiltered, state) end)

        frame_count = state.frame_count + 1
        run_quality? = rem(frame_count, state.quality_every_n) == 0

        {quality_ns, quality_samples} =
          if run_quality? do
            timed(fn -> measure_quality(raw_disparity, state.previous_disparity) end)
          else
            {0, nil}
          end

        {pack_ns, result} =
          timed(fn ->
            build_result(raw_disparity, left_frame, {left_rectified, right_rectified}, state)
          end)

        telemetry =
          state.telemetry
          |> Telemetry.record(:decode, decode_ns)
          |> Telemetry.record(:rectify, rectify_ns)
          |> Telemetry.record(:clahe, clahe_ns)
          |> Telemetry.record(:sgbm, sgbm_ns)
          |> Telemetry.record(:post, post_filter_ns)
          |> Telemetry.record(:pack, pack_ns)
          |> maybe_record_quality(quality_ns, quality_samples)

        previous_disparity = if run_quality?, do: raw_disparity, else: state.previous_disparity

        {{:ok, result},
         %{
           state
           | telemetry: telemetry,
             previous_disparity: previous_disparity,
             frame_count: frame_count
         }}

      {:error, reason} ->
        telemetry = Telemetry.record(state.telemetry, :decode, decode_ns)
        {{:error, reason}, %{state | telemetry: telemetry}}
    end
  end

  defp timed(fun) do
    start_ns = System.monotonic_time(:nanosecond)
    returned = fun.()
    {System.monotonic_time(:nanosecond) - start_ns, returned}
  end

  # Logged only; not part of the published depth.
  defp measure_quality(raw_disparity, previous_disparity) do
    valid_mask = Evision.compare(raw_disparity, 0, Evision.Constant.cv_CMP_GT())
    valid_count = Evision.countNonZero(valid_mask)
    {height, width} = image_size(raw_disparity)
    pixel_count = height * width
    valid_percent = if pixel_count > 0, do: 100.0 * valid_count / pixel_count, else: 0.0

    {mean_px, standard_deviation_px} =
      if valid_count > 0 do
        disparity_f32 = Evision.Mat.as_type(raw_disparity, :f32)

        case Evision.meanStdDev(disparity_f32, mask: valid_mask) do
          {mean_vector, standard_deviation_vector} ->
            {first_number(mean_vector) / @disparity_fixed_point_scale,
             first_number(standard_deviation_vector) / @disparity_fixed_point_scale}
        end
      else
        {0.0, 0.0}
      end

    %{
      valid_percent: valid_percent,
      mean_disparity_px: mean_px,
      disparity_standard_deviation_px: standard_deviation_px,
      jitter_px: temporal_jitter(raw_disparity, previous_disparity, valid_mask)
    }
  end

  defp temporal_jitter(_current, nil, _mask), do: 0.0

  defp temporal_jitter(current, previous, valid_mask) do
    previous_mask = Evision.compare(previous, 0, Evision.Constant.cv_CMP_GT())
    both_valid = Evision.Mat.bitwise_and(valid_mask, previous_mask)

    case Evision.countNonZero(both_valid) do
      0 ->
        0.0

      _ ->
        current_f32 = Evision.Mat.as_type(current, :f32)
        previous_f32 = Evision.Mat.as_type(previous, :f32)
        delta = Evision.absdiff(current_f32, previous_f32)

        first_number(Evision.mean(delta, mask: both_valid)) / @disparity_fixed_point_scale
    end
  end

  defp image_size(mat) do
    case Evision.Mat.shape(mat) do
      {height, width} -> {height, width}
      {height, width, _channels} -> {height, width}
    end
  end

  defp first_number(mat_tuple_or_number) do
    case mat_tuple_or_number do
      %Evision.Mat{} = mat ->
        case Evision.Mat.to_nx(mat) |> Nx.backend_transfer() |> Nx.to_flat_list() do
          [first | _] -> first
          [] -> 0.0
        end

      tuple when is_tuple(tuple) and tuple_size(tuple) > 0 ->
        elem(tuple, 0)

      number when is_number(number) ->
        number

      _ ->
        0.0
    end
  end

  defp maybe_record_quality(telemetry, _quality_ns, nil), do: telemetry

  defp maybe_record_quality(telemetry, quality_ns, samples) do
    telemetry
    |> Telemetry.record(:quality, quality_ns)
    |> record_quality_samples(samples)
  end

  defp record_quality_samples(telemetry, %{
         valid_percent: valid_percent,
         mean_disparity_px: mean_px,
         disparity_standard_deviation_px: standard_deviation_px,
         jitter_px: jitter_px
       }) do
    telemetry
    |> Telemetry.record_scalar(:valid, valid_percent, "%")
    |> Telemetry.record_scalar(:mean_disp, mean_px, "px")
    |> Telemetry.record_scalar(:std_disp, standard_deviation_px, "px")
    |> Telemetry.record_scalar(:jitter, jitter_px, "px")
  end

  # Grayscale: SGBM is single-channel, and rectification remaps one channel instead of three.
  defp decode_jpeg(%Frame{jpeg: jpeg}) do
    case Evision.imdecode(jpeg, Evision.Constant.cv_IMREAD_GRAYSCALE()) do
      %Evision.Mat{} = mat -> {:ok, mat}
      other -> {:error, {:imdecode_failed, other}}
    end
  end

  # CV_16SC2: map_x holds both axes; see `RosBridge.Perception.Fusion.remap/4`.
  defp left_rectification_map(%{rectification_maps: %{left: {map_x, _map_y}}}), do: map_x
  defp left_rectification_map(_state), do: nil

  # No maps: rectification is disabled.
  defp rectify_image(image, nil, _side), do: image

  defp rectify_image(image, %{left: maps_left, right: maps_right}, side) do
    {map_x, map_y} =
      case side do
        :left -> maps_left
        :right -> maps_right
      end

    Evision.remap(image, map_x, map_y, Evision.Constant.cv_INTER_LINEAR())
  end

  defp apply_clahe(nil, image), do: image
  defp apply_clahe(clahe, image), do: Evision.CLAHE.apply(clahe, image)

  # Median removes isolated wrong-disparity pixels.
  defp post_filter_disparity(disparity, %{post_filter: :none}), do: disparity

  defp post_filter_disparity(disparity, %{
         post_filter: :median,
         post_filter_kernel_size: kernel_size
       }) do
    Evision.medianBlur(disparity, kernel_size)
  end

  # CV_16S: pixels × 16, negative where unmatched.
  defp compute_disparity(matcher, left_gray, right_gray) do
    Evision.StereoSGBM.compute(matcher, left_gray, right_gray)
  end

  defp build_result(raw_disparity, left_frame, {reference_image, right_rectified}, state) do
    {height, width} = image_size(reference_image)

    {disparity_bytes, depth_bytes, depth_m} =
      pack_disparity_and_depth(raw_disparity, state.focal_length_px, state.baseline_m)

    {cloud, cloud_point_count} = build_point_cloud(depth_m, state)

    %Result{
      capture_ns: left_frame.capture_ns,
      width: width,
      height: height,
      disparity: disparity_bytes,
      disparity_step: width * 4,
      depth: depth_bytes,
      depth_step: width * 2,
      focal_length: state.focal_length_px,
      baseline: state.baseline_m,
      min_disparity: state.min_disparity / 1.0,
      max_disparity: (state.min_disparity + state.num_disparities - 1) / 1.0,
      delta_d: 1.0 / @disparity_fixed_point_scale,
      valid_x: state.min_disparity + state.num_disparities,
      valid_y: div(state.block_size, 2),
      valid_w: max(width - (state.min_disparity + state.num_disparities) - state.block_size, 0),
      valid_h: max(height - state.block_size, 0),
      cloud: cloud,
      cloud_points: cloud_point_count,
      left_rectified: reference_image,
      right_rectified: right_rectified,
      depth_m: depth_m,
      principal_point: state.principal_point,
      rectification_map_left: left_rectification_map(state)
    }
  end

  defp build_point_cloud(_depth_m, %{cloud_decimation: decimation}) when decimation <= 0,
    do: {nil, 0}

  # Explicit unprojection of the validated depth rather than `reprojectImageTo3D/2` + Q.
  defp build_point_cloud(depth_m, state) do
    {cx, cy} = state.principal_point
    step = state.cloud_decimation
    {height, width} = {elem(Evision.Mat.shape(depth_m), 0), elem(Evision.Mat.shape(depth_m), 1)}
    {cloud_width, cloud_height} = {div(width, step), div(height, step)}

    z =
      Evision.resize(depth_m, {cloud_width, cloud_height},
        interpolation: Evision.Constant.cv_INTER_NEAREST()
      )

    scale = 1.0 / step
    fx = state.focal_length_px * scale

    x =
      Evision.multiply(
        Evision.subtract(column_index_grid(cloud_width, cloud_height), cx * scale),
        Evision.divide(z, fx)
      )

    y =
      Evision.multiply(
        Evision.subtract(row_index_grid(cloud_width, cloud_height), cy * scale),
        Evision.divide(z, fx)
      )

    [x, y, z]
    |> Evision.merge()
    |> Evision.Mat.to_binary()
    |> pack_points_in_range()
  end

  defp column_index_grid(width, height) do
    row = for u <- 0..(width - 1), into: <<>>, do: <<u * 1.0::little-float-32>>
    Evision.Mat.from_binary(:binary.copy(row, height), {:f, 32}, height, width, 1)
  end

  defp row_index_grid(width, height) do
    binary =
      for v <- 0..(height - 1), into: <<>>, do: :binary.copy(<<v * 1.0::little-float-32>>, width)

    Evision.Mat.from_binary(binary, {:f, 32}, height, width, 1)
  end

  # Unmatched pixels (depth 0) are dropped, not packed as a phantom point at the origin.
  defp pack_points_in_range(binary) do
    for <<x::little-float-32, y::little-float-32, z::little-float-32 <- binary>>,
        z > @min_point_depth_m and z < @max_point_depth_m,
        reduce: {[], 0} do
      {chunks, count} ->
        {[<<x::little-float-32, y::little-float-32, z::little-float-32>> | chunks], count + 1}
    end
    |> then(fn {chunks, count} ->
      {chunks |> Enum.reverse() |> IO.iodata_to_binary(), count}
    end)
  end

  defp principal_point(%Calibration{projection_matrix: [_, _, cx, _, _, _, cy, _, _, _, _, _]}),
    do: {cx, cy}

  # Baseline from the right camera's rectified `P[0,3] = -fx × baseline`.
  defp stereo_geometry(%Calibration{projection_matrix: p_left}, %Calibration{
         projection_matrix: p_right
       }) do
    focal_length_px = Enum.at(p_left, 0)
    right_translation_term = Enum.at(p_right, 3)

    baseline_m =
      if focal_length_px > 0,
        do: -right_translation_term / focal_length_px,
        else: 0.0

    {focal_length_px, baseline_m}
  end

  @doc false
  def create_matcher(opts) do
    block_size = Keyword.get(opts, :block_size, 5)

    # OpenCV's recipe for one channel; without P1/P2 SGBM has no smoothness penalty.
    default_p1 = 8 * block_size * block_size
    default_p2 = 32 * block_size * block_size

    Evision.StereoSGBM.create(
      minDisparity: Keyword.get(opts, :min_disparity, 0),
      numDisparities: Keyword.get(opts, :num_disparities, 64),
      blockSize: block_size,
      mode: sgbm_mode(Keyword.get(opts, :mode, :sgbm_3way)),
      # The textbook value; lower if too sparse, higher if too noisy.
      uniquenessRatio: Keyword.get(opts, :uniqueness_ratio, 10),
      # 2, not the textbook 1: cameracalibrator rectification is not near-perfect.
      disp12MaxDiff: Keyword.get(opts, :disp12_max_diff, 2),
      preFilterCap: Keyword.get(opts, :pre_filter_cap, 31),
      # speckleRange is in ×16 fixed point.
      speckleWindowSize: Keyword.get(opts, :speckle_window_size, 100),
      speckleRange: Keyword.get(opts, :speckle_range, 32)
    )
    # Evision's create/1 accepts P1 and P2 but drops them: they read
    # back as 0, leaving SGBM without its smoothness penalties.
    |> Evision.StereoSGBM.setP1(Keyword.get(opts, :p1, default_p1))
    |> Evision.StereoSGBM.setP2(Keyword.get(opts, :p2, default_p2))
  end

  @integer_options %{
    uniqueness_ratio: {0, 100},
    speckle_window_size: {0, 10_000},
    speckle_range: {0, 256},
    p1: {0, 100_000},
    p2: {0, 400_000},
    disp12_max_diff: {-1, 64},
    pre_filter_cap: {1, 63},
    num_disparities: {16, 256}
  }

  @option_descriptions %{
    uniqueness_ratio: "Margin in percent by which the best match must beat the second best",
    speckle_window_size: "Largest region of disparity speckle removed, in pixels (0 disables)",
    speckle_range: "Disparity variation allowed within a connected region",
    p1: "Penalty for a disparity change of 1 between neighbours",
    p2: "Penalty for a larger disparity change between neighbours",
    disp12_max_diff: "Left-right consistency tolerance in pixels (-1 disables)",
    pre_filter_cap: "Clamp of the prefiltered image",
    num_disparities: "Disparity search range in pixels, a multiple of 16; sets the near limit",
    clahe: "Local contrast equalisation before matching",
    clahe_clip_limit: "Contrast limit of the equalisation"
  }

  @doc """
  The settings `set_options/2` accepts, as `{key, spec}` with `:type`
  (`:integer`, `:double` or `:bool`), `:range` and `:description`.
  `num_disparities` must also be a multiple of 16.
  """
  def option_specs do
    integers = for {key, range} <- @integer_options, do: {key, %{type: :integer, range: range}}

    (integers ++
       [clahe: %{type: :bool}, clahe_clip_limit: %{type: :double, range: {0, 40}}])
    |> Enum.map(fn {key, spec} ->
      {key, Map.put(spec, :description, @option_descriptions[key])}
    end)
  end

  @doc false
  def validate_options(options) do
    Enum.find_value(options, :ok, fn {setting, requested} ->
      case option_error(setting, requested) do
        nil -> nil
        reason -> {:error, reason}
      end
    end)
  end

  defp option_error(:num_disparities, requested)
       when is_integer(requested) and rem(requested, 16) != 0,
       do: "num_disparities must be a multiple of 16, got #{requested}"

  defp option_error(setting, requested) when is_map_key(@integer_options, setting) do
    {low, high} = @integer_options[setting]

    if is_integer(requested) and requested >= low and requested <= high,
      do: nil,
      else: "#{setting} must be an integer within #{low}..#{high}, got #{inspect(requested)}"
  end

  defp option_error(:clahe, requested) when is_boolean(requested), do: nil

  defp option_error(:clahe_clip_limit, requested)
       when is_number(requested) and requested > 0 and requested <= 40,
       do: nil

  defp option_error(setting, requested),
    do: "unknown or invalid stereo setting #{inspect(setting)}: #{inspect(requested)}"

  defp apply_option({:uniqueness_ratio, ratio}, state),
    do: update_matcher(state, &Evision.StereoSGBM.setUniquenessRatio(&1, ratio))

  defp apply_option({:speckle_window_size, size}, state),
    do: update_matcher(state, &Evision.StereoSGBM.setSpeckleWindowSize(&1, size))

  defp apply_option({:speckle_range, range}, state),
    do: update_matcher(state, &Evision.StereoSGBM.setSpeckleRange(&1, range))

  defp apply_option({:p1, p1}, state),
    do: update_matcher(state, &Evision.StereoSGBM.setP1(&1, p1))

  defp apply_option({:p2, p2}, state),
    do: update_matcher(state, &Evision.StereoSGBM.setP2(&1, p2))

  defp apply_option({:disp12_max_diff, max_difference}, state),
    do: update_matcher(state, &Evision.StereoSGBM.setDisp12MaxDiff(&1, max_difference))

  defp apply_option({:pre_filter_cap, cap}, state),
    do: update_matcher(state, &Evision.StereoSGBM.setPreFilterCap(&1, cap))

  defp apply_option({:num_disparities, count}, state),
    do: %{
      update_matcher(state, &Evision.StereoSGBM.setNumDisparities(&1, count))
      | num_disparities: count
    }

  defp apply_option({:clahe, false}, state),
    do: %{state | clahe: nil, opts: Keyword.put(state.opts, :clahe, false)}

  defp apply_option({:clahe, true}, state),
    do: %{
      state
      | clahe: create_clahe(Keyword.put(state.opts, :clahe, true)),
        opts: Keyword.put(state.opts, :clahe, true)
    }

  defp apply_option({:clahe_clip_limit, clip_limit}, state) do
    opts = Keyword.put(state.opts, :clahe_clip_limit, clip_limit * 1.0)
    %{state | opts: opts, clahe: if(state.clahe, do: create_clahe(opts))}
  end

  defp update_matcher(state, fun), do: %{state | matcher: fun.(state.matcher)}

  defp create_clahe(opts) do
    Evision.createCLAHE(
      clipLimit: Keyword.get(opts, :clahe_clip_limit, 2.0),
      tileGridSize: Keyword.get(opts, :clahe_tile_grid_size, {8, 8})
    )
  end

  defp current_options(%{matcher: matcher} = state) do
    %{
      uniqueness_ratio: Evision.StereoSGBM.getUniquenessRatio(matcher),
      speckle_window_size: Evision.StereoSGBM.getSpeckleWindowSize(matcher),
      speckle_range: Evision.StereoSGBM.getSpeckleRange(matcher),
      p1: Evision.StereoSGBM.getP1(matcher),
      p2: Evision.StereoSGBM.getP2(matcher),
      disp12_max_diff: Evision.StereoSGBM.getDisp12MaxDiff(matcher),
      pre_filter_cap: Evision.StereoSGBM.getPreFilterCap(matcher),
      num_disparities: Evision.StereoSGBM.getNumDisparities(matcher),
      clahe: not is_nil(state.clahe),
      clahe_clip_limit: Keyword.get(state.opts, :clahe_clip_limit, 2.0)
    }
  end

  # :sgbm_3way (the default) trades a little quality for speed over the 5-path :sgbm.
  defp sgbm_mode(:sgbm), do: Evision.StereoSGBM.cv_MODE_SGBM()
  defp sgbm_mode(:hh), do: Evision.StereoSGBM.cv_MODE_HH()
  defp sgbm_mode(:sgbm_3way), do: Evision.StereoSGBM.cv_MODE_SGBM_3WAY()
  defp sgbm_mode(:hh4), do: Evision.StereoSGBM.cv_MODE_HH4()

  # Maps for `Evision.remap/4`: undistortion plus the rectifying rotation.
  defp build_rectification_maps(%Calibration{} = calibration) do
    camera_matrix = matrix_3x3(calibration.camera_matrix)
    distortion = distortion_vector(calibration.distortion_coefficients)
    rectification = matrix_3x3(calibration.rectification_matrix)
    new_camera_matrix = projection_matrix_to_camera_matrix(calibration.projection_matrix)
    size = {calibration.width, calibration.height}

    Evision.initUndistortRectifyMap(
      camera_matrix,
      distortion,
      rectification,
      new_camera_matrix,
      size,
      Evision.Constant.cv_16SC2()
    )
  end

  # The 3×3 left submatrix.
  defp projection_matrix_to_camera_matrix(projection_matrix)
       when is_list(projection_matrix) and length(projection_matrix) == 12 do
    [0, 1, 2, 4, 5, 6, 8, 9, 10]
    |> Enum.map(&Enum.at(projection_matrix, &1))
    |> matrix_3x3()
  end

  defp matrix_3x3(values) when length(values) == 9 do
    values
    |> Enum.chunk_every(3)
    |> Nx.tensor(type: :f64)
    |> Evision.Mat.from_nx_2d()
  end

  # No distortion: five zero coefficients.
  defp distortion_vector([]) do
    Nx.tensor([0.0, 0.0, 0.0, 0.0, 0.0], type: :f64) |> Evision.Mat.from_nx_2d()
  end

  defp distortion_vector(coefficients) when is_list(coefficients) do
    [coefficients]
    |> Nx.tensor(type: :f64)
    |> Evision.Mat.from_nx_2d()
  end

  defp log_ready(focal_length_px, baseline_m, opts, rectify?, width, height) do
    Logger.info(
      "#{__MODULE__} ready " <>
        "(#{width}×#{height}, " <>
        "fx=#{Float.round(focal_length_px, 2)} px, " <>
        "baseline=#{Float.round(baseline_m, 4)} m, " <>
        "num_disparities=#{Keyword.get(opts, :num_disparities, 64)}, " <>
        "block_size=#{Keyword.get(opts, :block_size, 5)}, " <>
        "rectify=#{rectify?})"
    )
  end

  # Unclamped disparity keeps SGBM's unmatched sentinel below min_disparity, as consumers expect.
  defp pack_disparity_and_depth(raw_disparity, focal_length_px, baseline_m) do
    disparity_f32 = Evision.Mat.as_type(raw_disparity, :f32)

    disparity_bytes =
      disparity_f32
      |> Evision.divide(@disparity_fixed_point_scale)
      |> Evision.Mat.to_binary()

    # metres → millimetres in the same divide, so there is no extra
    # pass over the image.
    depth_scale = focal_length_px * baseline_m * @disparity_fixed_point_scale * 1000.0
    depth_mm = Evision.divide(depth_scale, disparity_f32)
    invalid_mask = Evision.compare(raw_disparity, 0, Evision.Constant.cv_CMP_LE())

    depth_m =
      depth_mm
      |> Evision.Mat.setTo(0.0, invalid_mask)
      |> Evision.divide(1000.0)

    depth_bytes =
      depth_mm
      |> Evision.Mat.setTo(0.0, invalid_mask)
      # Saturates: a far reading pins at the ceiling instead of aliasing near.
      |> Evision.Mat.as_type(:u16)
      |> Evision.Mat.to_binary()

    {disparity_bytes, depth_bytes, depth_m}
  end
end
