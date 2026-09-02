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

      decode_jpeg                              # JPEG bytes → single-channel Mat
        ↓
      rectify_image                            # apply undistortion + rectification LUT
        ↓
      compute_disparity                        # SGBM → CV_16S Mat (pixels × 16)
        ↓
      build_result                             # pack 32FC1 disparity (px) + 32FC1 depth (m)

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
       principal_point: principal_point(left_calibration),
       cloud_decimation: Keyword.get(opts, :cloud_decimation, 4),
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
      {:ok, {left_image, right_image}} ->
        {rectify_ns, {left_rectified, right_rectified}} =
          time(fn ->
            {
              rectify_image(left_image, state.rectification_maps, :left),
              rectify_image(right_image, state.rectification_maps, :right)
            }
          end)

        {clahe_ns, {left_eq, right_eq}} =
          time(fn ->
            {apply_clahe(state.clahe, left_rectified), apply_clahe(state.clahe, right_rectified)}
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

  # 1) JPEG bytes → single-channel Mat. Returns {:error, reason} so
  #    the pipeline's `with` short-circuits on a corrupt frame.
  #
  #    Grayscale rather than BGR because nothing downstream wants
  #    colour: SGBM is single-channel, and `build_result/4` only ever
  #    asked the reference image for its dimensions. Decoding straight
  #    to grey also lets libjpeg skip chroma upsampling, and — the
  #    larger saving — leaves `rectify_image/3` remapping one channel
  #    instead of three.
  defp decode_jpeg(%Frame{jpeg: jpeg}) do
    case Evision.imdecode(jpeg, Evision.Constant.cv_IMREAD_GRAYSCALE()) do
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

  # 5) Build the Result struct: pack 32FC1 disparity + 32FC1 depth
  #    + the geometry metadata downstream consumers need.
  defp build_result(raw_disparity, left_frame, reference_image, state) do

    # Single-channel Mats report a 2-tuple shape; the 3-tuple clause is
    # kept so a caller passing a colour reference still works.
    {height, width} =
      case Evision.Mat.shape(reference_image) do
        {h, w} -> {h, w}
        {h, w, _channels} -> {h, w}
      end

    {disparity_bytes, depth_bytes, depth_m} =
      pack_disparity_and_depth(raw_disparity, state.focal_length, state.baseline)

    {cloud, points} = build_point_cloud(depth_m, state)

    %Result{
      capture_ns: left_frame.capture_ns,
      width: width,
      height: height,
      disparity: disparity_bytes,
      disparity_step: width * 4,
      depth: depth_bytes,
      depth_step: width * 2,
      focal_length: state.focal_length,
      baseline: state.baseline,
      min_disparity: state.min_disparity / 1.0,
      max_disparity: (state.min_disparity + state.num_disparities - 1) / 1.0,
      delta_d: 1.0 / @disparity_fixed_point_scale,
      valid_x: state.min_disparity + state.num_disparities,
      valid_y: div(state.block_size, 2),
      valid_w: max(width - (state.min_disparity + state.num_disparities) - state.block_size, 0),
      valid_h: max(height - state.block_size, 0),
      cloud: cloud,
      cloud_points: points
    }
  end

  # Unproject the disparity into metric XYZ. A depth image needs
  # intrinsics, a depth scale and a consumer that knows to unproject
  # it — three things that each failed silently while getting a 3D
  # view working. A point cloud carries explicit metres and leaves
  # nothing to interpret.
  #
  # Decimated because the full grid is 12 bytes a pixel: at 480x270 and
  # 12 Hz that is 8 MB/s on a link already carrying disparity and
  # depth, and the session drops what it cannot drain. Every 4th pixel
  # in each axis is ~1.2 MB/s.
  defp build_point_cloud(_depth_m, %{cloud_decimation: d}) when d <= 0, do: {nil, 0}

  # Unproject the metric depth into XYZ with explicit arithmetic
  # rather than `reprojectImageTo3D/2` + a Q matrix. The depth Mat is
  # already validated end to end — it matches f*T/disparity to 0.03 mm
  # on the wire — so building on it means the only inputs are numbers
  # this module already trusts.
  #
  # Decimated because the full grid is 12 bytes a pixel: 480x270 at
  # 12 Hz is 8 MB/s on a link already carrying disparity and depth,
  # and the session drops what it cannot drain. Sampling every 4th
  # pixel costs ~1.2 MB/s. Intrinsics scale with the sampling, exactly
  # as they do for a resize.
  defp build_point_cloud(depth_m, state) do
    {cx, cy} = state.principal_point
    step = state.cloud_decimation
    {height, width} = {elem(Evision.Mat.shape(depth_m), 0), elem(Evision.Mat.shape(depth_m), 1)}
    {w, h} = {div(width, step), div(height, step)}

    z = Evision.resize(depth_m, {w, h}, interpolation: Evision.Constant.cv_INTER_NEAREST())

    scale = 1.0 / step
    fx = state.focal_length * scale

    x = Evision.multiply(Evision.subtract(u_grid(w, h), cx * scale), Evision.divide(z, fx))
    y = Evision.multiply(Evision.subtract(v_grid(w, h), cy * scale), Evision.divide(z, fx))

    [x, y, z]
    |> Evision.merge()
    |> Evision.Mat.to_binary()
    |> pack_finite_points()
  end

  # Column / row index grids. Built per call rather than cached: at
  # 120x67 this is 8k floats, far cheaper than the SGBM pass it sits
  # behind, and caching would mean invalidating on every resolution
  # change.
  defp u_grid(w, h) do
    row = for u <- 0..(w - 1), into: <<>>, do: <<u * 1.0::little-float-32>>
    Evision.Mat.from_binary(:binary.copy(row, h), {:f, 32}, h, w, 1)
  end

  defp v_grid(w, h) do
    binary = for v <- 0..(h - 1), into: <<>>, do: :binary.copy(<<v * 1.0::little-float-32>>, w)
    Evision.Mat.from_binary(binary, {:f, 32}, h, w, 1)
  end

  # Drop the points that carry no measurement rather than encode
  # sentinels: an unmatched pixel has depth 0, and a phantom obstacle
  # at the origin is worse than no point at all.
  defp pack_finite_points(binary) do
    for <<x::little-float-32, y::little-float-32, z::little-float-32 <- binary>>,
        z > 0.05 and z < 20.0,
        reduce: {[], 0} do
      {acc, n} ->
        {[<<x::little-float-32, y::little-float-32, z::little-float-32>> | acc], n + 1}
    end
    |> then(fn {chunks, n} -> {chunks |> Enum.reverse() |> IO.iodata_to_binary(), n} end)
  end

  defp principal_point(%Calibration{projection_matrix: [_, _, cx, _, _, _, cy, _, _, _, _, _]}),
    do: {cx, cy}

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
      # 10 % is the textbook sweet spot once epipolar geometry is
      # real; tune lower if too sparse, higher if too noisy.
      uniquenessRatio: Keyword.get(opts, :uniqueness_ratio, 10),
      # Left-right consistency: invalidate pixels where the
      # left→right and right→left disparities disagree by more
      # than `disp12_max_diff` px. 1 is the textbook value but
      # requires near-perfect rectification; 2 is a pragmatic
      # default for cameracalibrator-grade calibration (≈ 0.9 px
      # reprojection error). Set to -1 to disable.
      disp12MaxDiff: Keyword.get(opts, :disp12_max_diff, 2),
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

  # Lives on the Calibration struct so the publisher can apply the
  # same scaling to the CameraInfo it advertises.
  defp scale_calibration_to(%Calibration{} = calibration, actual_width, actual_height),
    do: Calibration.scale_to(calibration, actual_width, actual_height)

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
  #   * 32FC1 disparity in true pixels — what `stereo_msgs/
  #     DisparityImage.image` is specified to carry (and what
  #     `stereo_image_proc` publishes). Dividing the raw CV_16S by 16
  #     also maps SGBM's invalid sentinel, `(min_disparity − 1) × 16`,
  #     onto `min_disparity − 1`, which is exactly the convention
  #     consumers filter on (`disp < min_disparity`). So no clamping:
  #     it would erase the "no match here" signal.
  #   * 16UC1 depth (millimetres): `depth = (f × B × 16) / disp_signed`,
  #     scaled to mm and clamped to 65535. Invalid pixels become 0,
  #     the ROS depth_image "no measurement" convention.
  #
  #     Millimetres in uint16 rather than metres in float32 because
  #     the two are the same information at half the bytes, and the
  #     pair of full-size float images was too much for one Zenoh
  #     session: published second in the same tick, 32FC1 depth was
  #     being dropped down to ~1.2 Hz while disparity held 7 Hz.
  #     1 mm resolution over 65 m is far past anything a 90 mm
  #     baseline can resolve, so nothing measurable is lost.
  defp pack_disparity_and_depth(raw_disparity, focal_length, baseline) do
    disp_f32 = Evision.Mat.as_type(raw_disparity, :f32)

    disparity_bytes =
      disp_f32
      |> Evision.divide(@disparity_fixed_point_scale)
      |> Evision.Mat.to_binary()
    # metres → millimetres in the same divide, so there is no extra
    # pass over the image.
    depth_scale = focal_length * baseline * @disparity_fixed_point_scale * 1000.0
    depth_raw = Evision.divide(depth_scale, disp_f32)
    invalid_mask = Evision.compare(raw_disparity, 0, Evision.Constant.cv_CMP_LE())

    depth_m =
      depth_raw
      |> Evision.Mat.setTo(0.0, invalid_mask)
      |> Evision.divide(1000.0)

    depth_bytes =
      depth_raw
      |> Evision.Mat.setTo(0.0, invalid_mask)
      # `as_type(:u16)` saturates rather than wrapping, so anything
      # beyond 65.5 m pins at the ceiling instead of aliasing to a
      # near reading — a wrong-but-far value is far safer here than a
      # wrong-and-close one.
      |> Evision.Mat.as_type(:u16)
      |> Evision.Mat.to_binary()

    {disparity_bytes, depth_bytes, depth_m}
  end
end
