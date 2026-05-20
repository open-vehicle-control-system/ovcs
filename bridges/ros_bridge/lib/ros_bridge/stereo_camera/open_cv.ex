defmodule RosBridge.StereoCamera.OpenCV do
  @moduledoc """
  Classical stereo-depth backend backed by Evision's `StereoSGBM`
  (semi-global block matching). Works on host and target with the
  same code — the only difference is which camera driver feeds the
  frames.

  The bridge currently has exactly one stereo depth backend
  (this one), so there's no behaviour module —
  `Publishers.StereoCamera` and `StereoCamera.Supervisor` talk
  to this module by name. If/when a second backend lands (e.g.
  neural depth on Hailo) reintroduce a small
  `RosBridge.StereoCamera.Backend` behaviour declaring
  `register_listener/2` + `submit_pair/3`.

  ## Pipeline (per submitted pair)

      decode_jpeg                              # JPEG bytes → BGR Mat
        ↓
      rectify_image                            # apply undistortion + rectification LUT
        ↓
      convert_to_grayscale                     # SGBM consumes single-channel
        ↓
      compute_disparity                        # SGBM → CV_16S Mat (pixels × 16)
        ↓
      build_result                             # pack 16UC1 disparity + 32FC1 depth (metres)

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
    * `:num_disparities` (64), `:block_size` (5), `:min_disparity`
      (0) — `Evision.StereoSGBM` parameters.
    * `:name` — GenServer name (default `__MODULE__`).
  """
  use GenServer
  require Logger

  alias RosBridge.Camera.Calibration
  alias RosBridge.Camera.Frame
  alias RosBridge.StereoCamera.Result
  alias RosBridge.StereoCamera.Telemetry

  # SGBM's native fixed-point: stored disparity = pixels × 16.
  @disparity_fixed_point_scale 16.0

  # ── public API ───────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def register_listener(server, listener),
    do: GenServer.cast(server, {:register_listener, listener})

  def submit_pair(server, %Frame{} = left, %Frame{} = right),
    do: GenServer.cast(server, {:submit_pair, left, right})

  @doc """
  Reload calibration + rectification maps from the side YAMLs
  currently on disk. Used after a `set_camera_info` service call
  rewrites them — lets the next disparity reflect the new
  geometry without restarting the bridge.
  """
  def reload_calibration(server) do
    GenServer.call(server, :reload_calibration)
  end

  # ── GenServer callbacks ──────────────────────────────────────

  @impl true
  def init(opts) do
    left_calibration_raw =
      Calibration.load!(Keyword.fetch!(opts, :left_calibration_path))

    right_calibration_raw =
      Calibration.load!(Keyword.fetch!(opts, :right_calibration_path))

    # Calibrations are saved at whatever resolution the calibration
    # session was captured at; the cameras may run at a different
    # one (typically smaller, for SGBM throughput). Scale K and P
    # to the actual capture resolution so `initUndistortRectifyMap`
    # produces maps that match — otherwise `Evision.remap` would
    # silently upsample every frame back to the calibration's
    # resolution, eating any compute savings.
    actual_width = Keyword.fetch!(opts, :width)
    actual_height = Keyword.fetch!(opts, :height)

    left_calibration =
      scale_calibration_to(left_calibration_raw, actual_width, actual_height)

    right_calibration =
      scale_calibration_to(right_calibration_raw, actual_width, actual_height)

    {focal_length, baseline} = stereo_geometry(left_calibration, right_calibration)
    matcher = create_matcher(opts)

    # Optional CLAHE (Contrast-Limited Adaptive Histogram
    # Equalization) on the grayscale inputs before SGBM. Locally
    # equalizes contrast so SGBM's gradient-based cost has more
    # signal to work with in low-texture regions — calibration-
    # independent, ~1 ms total at 640×480.
    clahe =
      if Keyword.get(opts, :clahe, true) do
        Evision.createCLAHE(
          clipLimit: Keyword.get(opts, :clahe_clip_limit, 2.0),
          tileGridSize: Keyword.get(opts, :clahe_tile_grid_size, {8, 8})
        )
      else
        nil
      end

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

    log_ready(focal_length, baseline, opts, rectify?, actual_width, actual_height)

    {:ok,
     %{
       listeners: [],
       matcher: matcher,
       focal_length: focal_length,
       baseline: baseline,
       num_disparities: Keyword.get(opts, :num_disparities, 64),
       block_size: Keyword.get(opts, :block_size, 5),
       min_disparity: Keyword.get(opts, :min_disparity, 0),
       rectification_maps: rectification_maps,
       rectify?: rectify?,
       clahe: clahe,
       post_filter: Keyword.get(opts, :post_filter, :median),
       post_filter_ksize: Keyword.get(opts, :post_filter_ksize, 5),
       previous_disparity: nil,
       frame_count: 0,
       quality_every_n: Keyword.get(opts, :quality_every_n, 5),
       telemetry: Telemetry.new(window: 30, label: "backend"),
       last_total_at: nil,
       opts: opts
     }}
  end

  @impl true
  def handle_call(:reload_calibration, _from, state) do
    opts = state.opts

    try do
      left_raw = Calibration.load!(Keyword.fetch!(opts, :left_calibration_path))
      right_raw = Calibration.load!(Keyword.fetch!(opts, :right_calibration_path))

      actual_width = Keyword.fetch!(opts, :width)
      actual_height = Keyword.fetch!(opts, :height)

      left = scale_calibration_to(left_raw, actual_width, actual_height)
      right = scale_calibration_to(right_raw, actual_width, actual_height)
      {focal_length, baseline} = stereo_geometry(left, right)

      maps =
        if state.rectify? do
          %{left: build_rectification_maps(left), right: build_rectification_maps(right)}
        else
          nil
        end

      Logger.info(
        "#{__MODULE__} reloaded calibration " <>
          "(fx=#{Float.round(focal_length, 2)} px, baseline=#{Float.round(baseline, 4)} m)"
      )

      {:reply, :ok,
       %{
         state
         | focal_length: focal_length,
           baseline: baseline,
           rectification_maps: maps,
           previous_disparity: nil
       }}
    rescue
      error ->
        Logger.warning("#{__MODULE__}: reload_calibration failed: #{inspect(error)}")
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  def handle_cast({:submit_pair, %Frame{} = left, %Frame{} = right}, state) do
    total_start = System.monotonic_time(:nanosecond)

    {result_or_error, state} = run_pipeline(left, right, state)

    case result_or_error do
      {:ok, %Result{} = result} ->
        Enum.each(state.listeners, &GenServer.cast(&1, {:stereo_result, result}))

      {:error, reason} ->
        Logger.warning("#{__MODULE__}: stereo pipeline failed: #{inspect(reason)}")
    end

    total = System.monotonic_time(:nanosecond) - total_start

    telemetry =
      state.telemetry
      |> Telemetry.record(:total, total)
      |> Telemetry.record(:wall, wall_since(state.last_total_at, total_start))
      |> Telemetry.tick()

    {:noreply, %{state | telemetry: telemetry, last_total_at: total_start}}
  end

  defp wall_since(nil, _now), do: 0
  defp wall_since(previous, now), do: now - previous

  # ── the pipeline ─────────────────────────────────────────────

  defp run_pipeline(%Frame{} = left_frame, %Frame{} = right_frame, state) do
    {decode_ns, decoded} =
      time(fn ->
        with {:ok, left} <- decode_jpeg(left_frame),
             {:ok, right} <- decode_jpeg(right_frame),
             do: {:ok, {left, right}}
      end)

    case decoded do
      {:ok, {left_color, right_color}} ->
        {rectify_ns, {left_rectified, right_rectified}} =
          time(fn ->
            {
              rectify_image(left_color, state.rectification_maps, :left),
              rectify_image(right_color, state.rectification_maps, :right)
            }
          end)

        {gray_ns, {left_gray, right_gray}} =
          time(fn ->
            {convert_to_grayscale(left_rectified), convert_to_grayscale(right_rectified)}
          end)

        {clahe_ns, {left_eq, right_eq}} =
          time(fn ->
            {apply_clahe(state.clahe, left_gray), apply_clahe(state.clahe, right_gray)}
          end)

        {sgbm_ns, raw_disparity_unfiltered} =
          time(fn -> compute_disparity(state.matcher, left_eq, right_eq) end)

        {post_ns, raw_disparity} =
          time(fn -> post_filter_disparity(raw_disparity_unfiltered, state) end)

        frame_count = state.frame_count + 1
        run_quality? = rem(frame_count, state.quality_every_n) == 0

        {quality_ns, quality_samples} =
          if run_quality? do
            time(fn -> measure_quality(raw_disparity, state.previous_disparity) end)
          else
            {0, nil}
          end

        {pack_ns, result} =
          time(fn -> build_result(raw_disparity, left_frame, left_rectified, state) end)

        telemetry =
          state.telemetry
          |> Telemetry.record(:decode, decode_ns)
          |> Telemetry.record(:rectify, rectify_ns)
          |> Telemetry.record(:gray, gray_ns)
          |> Telemetry.record(:clahe, clahe_ns)
          |> Telemetry.record(:sgbm, sgbm_ns)
          |> Telemetry.record(:post, post_ns)
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

  defp time(fun) do
    start = System.monotonic_time(:nanosecond)
    value = fun.()
    {System.monotonic_time(:nanosecond) - start, value}
  end

  # Cheap quality probe — all OpenCV calls, sub-millisecond. Used
  # only for logging; result is not part of the published depth.
  #
  #   * valid_ratio : fraction of pixels with disparity > 0 (after
  #     SGBM's invalid sentinel of negative values). Lower bound is
  #     ~num_disparities/width (the leftmost band can never match);
  #     anything below that is uniform/untextured input, anything
  #     well above suggests a healthy stereo pair.
  #   * mean_disp_px / std_disp_px : in actual disparity pixels
  #     (SGBM stores ×16 fixed-point, we divide).
  defp measure_quality(raw_disparity, previous_disparity) do
    valid_mask = Evision.compare(raw_disparity, 0, Evision.Constant.cv_CMP_GT())
    valid_count = Evision.countNonZero(valid_mask)
    {h, w} = mat_hw(raw_disparity)
    total = h * w
    valid_ratio = if total > 0, do: 100.0 * valid_count / total, else: 0.0

    {mean_px, std_px} =
      if valid_count > 0 do
        disp_f32 = Evision.Mat.as_type(raw_disparity, :f32)

        case Evision.meanStdDev(disp_f32, mask: valid_mask) do
          {{mean_vec, std_vec}, _opt} -> {scalar(mean_vec) / 16.0, scalar(std_vec) / 16.0}
          {mean_vec, std_vec} -> {scalar(mean_vec) / 16.0, scalar(std_vec) / 16.0}
        end
      else
        {0.0, 0.0}
      end

    # Temporal jitter: mean absolute frame-to-frame change in
    # disparity over pixels valid in both this frame and the
    # previous one. On a roughly-static scene this isolates
    # algorithm noise (proper signal: 0). Reported in disparity
    # pixels.
    jitter_px = temporal_jitter(raw_disparity, previous_disparity, valid_mask)

    %{
      valid_ratio: valid_ratio,
      mean_disp: mean_px,
      std_disp: std_px,
      jitter: jitter_px
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

        scalar(Evision.mean(delta, mask: both_valid)) / 16.0
    end
  end

  defp mat_hw(mat) do
    case Evision.Mat.shape(mat) do
      {h, w} -> {h, w}
      {h, w, _c} -> {h, w}
    end
  end

  defp scalar(value) do
    case value do
      %Evision.Mat{} = mat ->
        case Evision.Mat.to_nx(mat) |> Nx.backend_transfer() |> Nx.to_flat_list() do
          [v | _] -> v
          [] -> 0.0
        end

      tuple when is_tuple(tuple) and tuple_size(tuple) > 0 -> elem(tuple, 0)
      [v | _] when is_number(v) -> v
      [[v | _] | _] when is_number(v) -> v
      v when is_number(v) -> v
      _ -> 0.0
    end
  end

  defp maybe_record_quality(telemetry, _ns, nil), do: telemetry

  defp maybe_record_quality(telemetry, ns, samples) do
    telemetry
    |> Telemetry.record(:quality, ns)
    |> record_quality_samples(samples)
  end

  defp record_quality_samples(telemetry, %{
         valid_ratio: ratio,
         mean_disp: mean,
         std_disp: std,
         jitter: jitter
       }) do
    telemetry
    |> Telemetry.record_scalar(:valid, ratio, "%")
    |> Telemetry.record_scalar(:mean_disp, mean, "px")
    |> Telemetry.record_scalar(:std_disp, std, "px")
    |> Telemetry.record_scalar(:jitter, jitter, "px")
  end

  # 1) JPEG bytes → BGR Mat. Returns {:error, reason} so the
  #    pipeline's `with` short-circuits on a corrupt frame.
  defp decode_jpeg(%Frame{jpeg: jpeg}) do
    case Evision.imdecode(jpeg, Evision.Constant.cv_IMREAD_COLOR()) do
      %Evision.Mat{} = mat -> {:ok, mat}
      other -> {:error, {:imdecode_failed, other}}
    end
  end

  # 2) Apply the precomputed undistort+rectify LUT for this side.
  #    No-op when rectification is disabled (rectification_maps == nil).
  defp rectify_image(image, nil, _side), do: image

  defp rectify_image(image, %{left: maps_left, right: maps_right}, side) do
    {map_x, map_y} =
      case side do
        :left -> maps_left
        :right -> maps_right
      end

    Evision.remap(image, map_x, map_y, Evision.Constant.cv_INTER_LINEAR())
  end

  # 3) StereoSGBM only takes single-channel images.
  defp convert_to_grayscale(image) do
    Evision.cvtColor(image, Evision.Constant.cv_COLOR_BGR2GRAY())
  end

  # 3b) Optional CLAHE — when disabled (`clahe: false` in opts)
  # the grayscale frame is passed through untouched.
  defp apply_clahe(nil, image), do: image
  defp apply_clahe(clahe, image), do: Evision.CLAHE.apply(clahe, image)

  # 4b) Optional post-filter on the raw 16SC1 SGBM disparity.
  # `:median` kills isolated wrong-disparity pixels (salt-and-
  # pepper noise) — the cheapest classical fix for frame-to-frame
  # jitter and works fine on signed-int16 input.
  defp post_filter_disparity(disparity, %{post_filter: :none}), do: disparity

  defp post_filter_disparity(disparity, %{post_filter: :median, post_filter_ksize: ksize}) do
    Evision.medianBlur(disparity, ksize)
  end

  # 4) Run the matcher. Returns a CV_16S Mat: signed int16 values
  #    are pixels × 16, negatives mean "no valid match".
  defp compute_disparity(matcher, left_gray, right_gray) do
    Evision.StereoSGBM.compute(matcher, left_gray, right_gray)
  end

  # 5) Build the Result struct: pack 16UC1 disparity + 32FC1 depth
  #    + the geometry metadata downstream consumers need.
  defp build_result(raw_disparity, left_frame, reference_image, state) do
    {height, width, _channels} = Evision.Mat.shape(reference_image)

    {disparity_bytes, depth_bytes} =
      pack_disparity_and_depth(raw_disparity, state.focal_length, state.baseline)

    %Result{
      capture_ns: left_frame.capture_ns,
      width: width,
      height: height,
      disparity: disparity_bytes,
      disparity_step: width * 2,
      depth: depth_bytes,
      depth_step: width * 4,
      focal_length: state.focal_length,
      baseline: state.baseline,
      min_disparity: state.min_disparity / 1.0,
      max_disparity: (state.min_disparity + state.num_disparities - 1) / 1.0,
      delta_d: 1.0 / @disparity_fixed_point_scale,
      valid_x: state.min_disparity + state.num_disparities,
      valid_y: div(state.block_size, 2),
      valid_w: max(width - (state.min_disparity + state.num_disparities) - state.block_size, 0),
      valid_h: max(height - state.block_size, 0)
    }
  end

  # ── init helpers ─────────────────────────────────────────────

  # Focal length comes from either side's rectified P (they're
  # equal after rectification). Baseline reads off the right
  # camera's `P[0,3] = -fx × baseline` term.
  defp stereo_geometry(%Calibration{projection_matrix: p_left}, %Calibration{
         projection_matrix: p_right
       }) do
    focal_length = Enum.at(p_left, 0)
    right_translation_term = Enum.at(p_right, 3)

    baseline =
      if focal_length > 0,
        do: -right_translation_term / focal_length,
        else: 0.0

    {focal_length, baseline}
  end

  defp create_matcher(opts) do
    block_size = Keyword.get(opts, :block_size, 5)

    # Defaults follow OpenCV's documentation recipe for SGBM:
    #   P1 = 8 × channels × bs²   smoothness penalty for ±1 px
    #   P2 = 32 × channels × bs²  smoothness penalty for >1 px
    # Inputs are single-channel grayscale, so channels = 1.
    # Without these set, SGBM has no smoothness penalty at all and
    # produces a very speckly disparity (the OpenCV default of 0/0
    # is essentially "block matching with extra steps").
    default_p1 = 8 * block_size * block_size
    default_p2 = 32 * block_size * block_size

    Evision.StereoSGBM.create(
      minDisparity: Keyword.get(opts, :min_disparity, 0),
      numDisparities: Keyword.get(opts, :num_disparities, 64),
      blockSize: block_size,
      mode: sgbm_mode(Keyword.get(opts, :mode, :sgbm_3way)),
      P1: Keyword.get(opts, :p1, default_p1),
      P2: Keyword.get(opts, :p2, default_p2),
      # Reject ambiguous matches (margin of best vs 2nd-best cost).
      # Textbook sweet spot is 10 %, but with the placeholder
      # calibration (no real rectification) the cost surface is
      # noisier, so we start lower and tighten once we have proper
      # epipolar geometry.
      uniquenessRatio: Keyword.get(opts, :uniqueness_ratio, 5),
      # Left-right consistency: invalidate pixels where the
      # left→right and right→left disparities disagree by more
      # than `disp12_max_diff` px. Calibration-sensitive — without
      # rectification, even correct matches fail the check. Off by
      # default; flip to 1 once calibration is real.
      disp12MaxDiff: Keyword.get(opts, :disp12_max_diff, -1),
      # Soft-clip the x-derivative before matching; trims response
      # to high-frequency texture and large gradient regions.
      preFilterCap: Keyword.get(opts, :pre_filter_cap, 31),
      # Speckle filter: invalidate connected components smaller
      # than `speckleWindowSize` whose internal disparity range
      # exceeds `speckleRange` (×16 fixed-point internally — so 32
      # means ~2 disparity pixels).
      speckleWindowSize: Keyword.get(opts, :speckle_window_size, 100),
      speckleRange: Keyword.get(opts, :speckle_range, 32)
    )
  end

  # SGBM aggregation modes. MODE_SGBM (5 paths) is the historical
  # default; MODE_SGBM_3WAY trades slight quality for ~2× speed and
  # is the right pick when we're CPU-bound at HD resolutions.
  defp sgbm_mode(:sgbm), do: Evision.StereoSGBM.cv_MODE_SGBM()
  defp sgbm_mode(:hh), do: Evision.StereoSGBM.cv_MODE_HH()
  defp sgbm_mode(:sgbm_3way), do: Evision.StereoSGBM.cv_MODE_SGBM_3WAY()
  defp sgbm_mode(:hh4), do: Evision.StereoSGBM.cv_MODE_HH4()

  # Rescale a calibration (originally saved at some reference
  # resolution) to the actual capture resolution. Pixel-indexed
  # intrinsics scale linearly: a 0.5× resize halves fx, fy, cx,
  # cy and halves every pixel-space term of P. The physical
  # baseline encoded in `P_right[0,3] = -fx × T` is preserved
  # because P_right[0,3] and P_right[0,0] both scale by the
  # same factor. Distortion coefficients D and the rectification
  # rotation R are resolution-invariant and stay untouched.
  defp scale_calibration_to(%Calibration{} = calibration, actual_width, actual_height)
       when actual_width > 0 and actual_height > 0 do
    reference_width = calibration.width
    reference_height = calibration.height

    cond do
      reference_width == 0 or reference_height == 0 ->
        # No reference dims in the YAML — pretend it was captured
        # at the requested resolution and trust the intrinsics.
        %{calibration | width: actual_width, height: actual_height}

      reference_width == actual_width and reference_height == actual_height ->
        calibration

      true ->
        scale_x = actual_width / reference_width
        scale_y = actual_height / reference_height

        %{
          calibration
          | width: actual_width,
            height: actual_height,
            camera_matrix: scale_3x3(calibration.camera_matrix, scale_x, scale_y),
            projection_matrix: scale_3x4(calibration.projection_matrix, scale_x, scale_y)
        }
    end
  end

  defp scale_3x3([a, b, c, d, e, f, g, h, i], scale_x, scale_y) do
    [
      a * scale_x, b * scale_x, c * scale_x,
      d * scale_y, e * scale_y, f * scale_y,
      g, h, i
    ]
  end

  defp scale_3x4(
         [r0c0, r0c1, r0c2, r0c3, r1c0, r1c1, r1c2, r1c3, r2c0, r2c1, r2c2, r2c3],
         scale_x,
         scale_y
       ) do
    [
      r0c0 * scale_x, r0c1 * scale_x, r0c2 * scale_x, r0c3 * scale_x,
      r1c0 * scale_y, r1c1 * scale_y, r1c2 * scale_y, r1c3 * scale_y,
      r2c0, r2c1, r2c2, r2c3
    ]
  end

  # Precomputes the (map_x, map_y) lookup tables that
  # `Evision.remap/4` consumes. For each output pixel they give
  # the (sub-pixel) source coordinates to sample from in the
  # original distorted image — combining undistortion + the
  # rotation that brings the image into the rectified stereo
  # frame.
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

  # The rectified camera intrinsics for `initUndistortRectifyMap`
  # are the 3×3 left submatrix of the rectified projection matrix.
  defp projection_matrix_to_camera_matrix(p) when is_list(p) and length(p) == 12 do
    [
      Enum.at(p, 0), Enum.at(p, 1), Enum.at(p, 2),
      Enum.at(p, 4), Enum.at(p, 5), Enum.at(p, 6),
      Enum.at(p, 8), Enum.at(p, 9), Enum.at(p, 10)
    ]
    |> matrix_3x3()
  end

  defp matrix_3x3(values) when length(values) == 9 do
    values
    |> Enum.chunk_every(3)
    |> Nx.tensor(type: :f64)
    |> Evision.Mat.from_nx_2d()
  end

  defp distortion_vector([]) do
    # Some calibrations omit distortion entirely. OpenCV accepts
    # an empty Mat as "no distortion".
    Nx.tensor([0.0, 0.0, 0.0, 0.0, 0.0], type: :f64) |> Evision.Mat.from_nx_2d()
  end

  defp distortion_vector(coefficients) when is_list(coefficients) do
    [coefficients]
    |> Nx.tensor(type: :f64)
    |> Evision.Mat.from_nx_2d()
  end

  defp log_ready(focal_length, baseline, opts, rectify?, width, height) do
    Logger.info(
      "#{__MODULE__} ready " <>
        "(#{width}×#{height}, " <>
        "fx=#{Float.round(focal_length, 2)} px, " <>
        "baseline=#{Float.round(baseline, 4)} m, " <>
        "num_disparities=#{Keyword.get(opts, :num_disparities, 64)}, " <>
        "block_size=#{Keyword.get(opts, :block_size, 5)}, " <>
        "rectify=#{rectify?})"
    )
  end

  # ── result-packing internals ─────────────────────────────────

  # SGBM returns CV_16S — signed int16, values are `actual_pixels
  # × 16`, negatives are invalid matches. We pack two ROS-native
  # buffers entirely inside OpenCV (C++) — the previous
  # Nx-BinaryBackend version did the same element-wise math in
  # pure Elixir loops and dominated the pipeline (~410 ms out of
  # 460 ms total at 640×480).
  #
  #   * 16UC1 disparity (ROS convention): same ×16 fixed-point,
  #     invalid pixels become 0. CV_16S's byte layout is identical
  #     to CV_16U for non-negative values, so a single
  #     `max(raw, 0) → to_binary` is enough.
  #   * 32FC1 depth (metres): `depth = (f × B × 16) / disp_signed`,
  #     invalid pixels become 0.0 (the ROS depth_image "no
  #     measurement" convention foxglove understands).
  defp pack_disparity_and_depth(raw_disparity, focal_length, baseline) do
    disparity_clamped = Evision.max(raw_disparity, 0)
    disparity_bytes = Evision.Mat.to_binary(disparity_clamped)

    disp_f32 = Evision.Mat.as_type(raw_disparity, :f32)
    depth_scale = focal_length * baseline * @disparity_fixed_point_scale
    depth_raw = Evision.divide(depth_scale, disp_f32)
    invalid_mask = Evision.compare(raw_disparity, 0, Evision.Constant.cv_CMP_LE())
    depth = Evision.Mat.setTo(depth_raw, 0.0, invalid_mask)
    depth_bytes = Evision.Mat.to_binary(depth)

    {disparity_bytes, depth_bytes}
  end
end
