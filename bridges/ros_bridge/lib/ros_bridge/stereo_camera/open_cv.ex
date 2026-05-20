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
       rectification_maps: rectification_maps
     }}
  end

  @impl true
  def handle_cast({:register_listener, listener}, state) do
    {:noreply, %{state | listeners: state.listeners ++ [listener]}}
  end

  def handle_cast({:submit_pair, %Frame{} = left, %Frame{} = right}, state) do
    case run_pipeline(left, right, state) do
      {:ok, %Result{} = result} ->
        Enum.each(state.listeners, &GenServer.cast(&1, {:stereo_result, result}))

      {:error, reason} ->
        Logger.warning("#{__MODULE__}: stereo pipeline failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # ── the pipeline ─────────────────────────────────────────────

  defp run_pipeline(%Frame{} = left_frame, %Frame{} = right_frame, state) do
    with {:ok, left_color}  <- decode_jpeg(left_frame),
         {:ok, right_color} <- decode_jpeg(right_frame),
         left_rectified  = rectify_image(left_color, state.rectification_maps, :left),
         right_rectified = rectify_image(right_color, state.rectification_maps, :right),
         left_gray  = convert_to_grayscale(left_rectified),
         right_gray = convert_to_grayscale(right_rectified) do
      raw_disparity = compute_disparity(state.matcher, left_gray, right_gray)
      {:ok, build_result(raw_disparity, left_frame, left_rectified, state)}
    end
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
    Evision.StereoSGBM.create(
      minDisparity: Keyword.get(opts, :min_disparity, 0),
      numDisparities: Keyword.get(opts, :num_disparities, 64),
      blockSize: Keyword.get(opts, :block_size, 5)
    )
  end

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

  # SGBM returns CV_16S — signed int16, values are
  # `actual_pixels × 16`, negatives are invalid matches. From
  # one Nx pass we derive two ROS-native buffers:
  #
  #   * 16UC1 disparity (ROS convention): same ×16 fixed-point,
  #     invalid pixels become 0.
  #   * 32FC1 depth (metres): `f × baseline / disparity_pixels`,
  #     invalid pixels become NaN.
  defp pack_disparity_and_depth(raw_disparity, focal_length, baseline) do
    signed_tensor = Evision.Mat.to_nx(raw_disparity) |> Nx.backend_transfer()

    invalid_mask = Nx.less_equal(signed_tensor, 0)

    disparity_unsigned =
      signed_tensor
      |> Nx.max(0)
      |> Nx.as_type(:u16)

    disparity_in_pixels =
      signed_tensor
      |> Nx.as_type(:f32)
      |> Nx.divide(@disparity_fixed_point_scale)

    raw_depth = Nx.divide(focal_length * baseline, disparity_in_pixels)
    nan_tensor = Nx.broadcast(Nx.Constants.nan(:f32), Nx.shape(raw_depth))
    depth = Nx.select(invalid_mask, nan_tensor, raw_depth)

    {Nx.to_binary(disparity_unsigned), Nx.to_binary(depth)}
  end
end
