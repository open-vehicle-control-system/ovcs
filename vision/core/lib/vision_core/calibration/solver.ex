defmodule VisionCore.Calibration.Solver do
  @moduledoc """
  Computes a calibration from chessboard corner samples: a stereo pair's,
  one camera's, or the pose of a camera relative to the stereo pair.

  Each camera is calibrated on its own (`plumb_bob`, `k3` fixed at 0). A
  pair is then solved for its relative pose with the intrinsics held fixed,
  and rectified with alpha 0 and zero disparity. A camera alone keeps an
  identity rectification, and its projection is its camera matrix refitted
  to the undistorted image with alpha 0. The results match what
  `cameracalibrator` writes, so the calibrations load like any other.

  A pose is solved between the stereo left camera and the camera with
  both calibrations held, then taken from the left camera's raw frame to
  its rectified one (`VisionCore.Camera.Pose`).
  """

  alias VisionCore.Calibration.Board
  alias VisionCore.Camera.Pose
  alias VisionCore.Ros2.CameraCalibration

  @min_samples 3
  # Both lenses held, only the pose's six values move: the solve runs until they settle.
  @pose_criteria {Evision.Constant.cv_EPS() + Evision.Constant.cv_MAX_ITER(), 100, 1.0e-10}
  @pose_distortion_model "plumb_bob"

  @type samples :: [%{left: [{float(), float()}], right: [{float(), float()}]}]

  @type result :: %{
          left: CameraCalibration.t(),
          right: CameraCalibration.t(),
          left_rms_px: float(),
          right_rms_px: float(),
          stereo_rms_px: float(),
          baseline_m: float(),
          fx_px: float(),
          samples: pos_integer()
        }

  @type camera_result :: %{
          camera: CameraCalibration.t(),
          rms_px: float(),
          fx_px: float(),
          samples: pos_integer()
        }

  @typedoc "A camera's calibration in force and the size, in pixels, of the frames its corners were found in."
  @type pose_camera :: %{calibration: CameraCalibration.t(), size: {pos_integer(), pos_integer()}}

  @type pose_samples :: [%{left: [{float(), float()}], camera: [{float(), float()}]}]

  @type pose_result :: %{
          pose: Pose.t(),
          rms_px: float(),
          distance_m: float(),
          samples: pos_integer()
        }

  @doc """
  Solves for the pose of a camera relative to the stereo pair from
  `samples`, the corners found in each pair of frames of the stereo left
  camera and the camera, as `VisionCore.Calibration.Chessboard.detect/2`
  returns them. `cameras` holds each one's calibration in force and the
  size of its frames: each calibration is resampled to that size, pixel
  centres onto pixel centres (`VisionCore.Ros2.CameraCalibration.resample_to/3`).

  OpenCV's `stereoCalibrate`, both intrinsics held, gives the transform
  from the left camera's raw frame to the camera's, `p_camera = R ×
  p_raw + t`. The left calibration's rectification `R_rect` maps the raw
  frame to the rectified one, so the pose is `R × R_rectᵀ` and `t`, in
  metres, as the board's squares are.

  Returns the pose, the RMS reprojection error over both cameras' corners,
  and the distance between the two cameras. Refuses a calibration that is
  not `#{@pose_distortion_model}` or of another aspect ratio than its frames.
  """
  @spec solve_pose(Board.t(), %{left: pose_camera(), camera: pose_camera()}, pose_samples()) ::
          {:ok, pose_result()} | {:error, String.t()}
  def solve_pose(_board, _cameras, samples) when length(samples) < @min_samples do
    {:error, "at least #{@min_samples} samples are needed, got #{length(samples)}"}
  end

  def solve_pose(%Board{} = board, %{left: left, camera: camera}, samples) do
    with {:ok, left_calibration} <- pose_calibration("the stereo cameras'", left),
         {:ok, camera_calibration} <- pose_calibration("the camera's", camera),
         {:ok, {rms, raw_rotation, translation}} <-
           stereo_pose(board, left_calibration, camera_calibration, camera.size, samples) do
      rectification = matrix(left_calibration.rectification_matrix)
      rotation = raw_rotation |> Nx.dot(Nx.transpose(rectification)) |> Nx.to_flat_list()
      pose = %Pose{rotation: rotation, translation: translation}

      {:ok,
       %{pose: pose, rms_px: rms, distance_m: Pose.distance_m(pose), samples: length(samples)}}
    end
  end

  @doc """
  Whether a pose can be solved with `calibration`, the calibration of
  `owner`, a possessive such as `"the camera's"`: `{:error, message}` for
  a distortion model other than `#{@pose_distortion_model}`.
  """
  @spec check_pose_calibration(CameraCalibration.t(), String.t()) :: :ok | {:error, String.t()}
  def check_pose_calibration(
        %CameraCalibration{distortion_model: @pose_distortion_model},
        _owner
      ),
      do: :ok

  def check_pose_calibration(%CameraCalibration{distortion_model: model}, owner),
    do:
      {:error,
       "#{owner} calibration is #{model}; a pose is solved with #{@pose_distortion_model} " <>
         "calibrations only"}

  # The calibration of `camera` at the size of its frames.
  defp pose_calibration(owner, %{calibration: calibration, size: {width, height}}) do
    with :ok <- check_pose_calibration(calibration, owner),
         :ok <- check_proportional(calibration, owner, width, height),
         do: {:ok, CameraCalibration.resample_to(calibration, width, height)}
  end

  defp check_proportional(calibration, owner, width, height) do
    if CameraCalibration.proportional?(calibration, width, height),
      do: :ok,
      else:
        {:error,
         "#{owner} calibration is for #{calibration.width}x#{calibration.height} images, of " <>
           "another aspect ratio than its #{width}x#{height} frames: calibrate it at that size"}
  end

  # The rotation and translation from the left camera's raw frame to the camera's.
  defp stereo_pose(board, left, camera, size, samples) do
    object_points = List.duplicate(object_mat(board), length(samples))

    case Evision.stereoCalibrate(
           object_points,
           Enum.map(samples, &image_mat(&1.left)),
           Enum.map(samples, &image_mat(&1.camera)),
           camera_mat(left),
           distortion_mat(left),
           camera_mat(camera),
           distortion_mat(camera),
           size,
           flags: Evision.Constant.cv_CALIB_FIX_INTRINSIC(),
           criteria: @pose_criteria
         ) do
      {:error, message} ->
        {:error, "the pose cannot be solved: #{message}"}

      # The essential and fundamental matrices follow, then the per-view errors where OpenCV gives them.
      solved when tuple_size(solved) >= 7 ->
        [rms, _k1, _d1, _k2, _d2, rotation, translation | _rest] = Tuple.to_list(solved)
        {:ok, {rms, Evision.Mat.to_nx(rotation, Nx.BinaryBackend), flatten(translation)}}
    end
  end

  defp camera_mat(calibration), do: calibration.camera_matrix |> matrix() |> Evision.Mat.from_nx()

  defp distortion_mat(calibration),
    do: Evision.Mat.from_nx(Nx.tensor([calibration.distortion_coefficients], type: :f64))

  defp matrix(flat), do: flat |> Nx.tensor(type: :f64) |> Nx.reshape({3, 3})

  @doc """
  Solves for one camera from `views`, the corners found in each of its
  frames, as `VisionCore.Calibration.Chessboard.detect/2` returns them.
  `size` is the capture size in pixels.

  Returns the calibration, its RMS reprojection error and the focal
  length of its projection in pixels.
  """
  @spec solve_camera(Board.t(), {pos_integer(), pos_integer()}, [[{float(), float()}]]) ::
          {:ok, camera_result()} | {:error, String.t()}
  def solve_camera(_board, _size, views) when length(views) < @min_samples do
    {:error, "at least #{@min_samples} samples are needed, got #{length(views)}"}
  end

  def solve_camera(%Board{} = board, {width, height} = size, views) do
    object_points = List.duplicate(object_mat(board), length(views))

    with {:ok, {rms, k, d}} <- calibrate(object_points, Enum.map(views, &image_mat/1), size),
         {:ok, projection} <- projection(k, d, size) do
      identity = flatten(Evision.Mat.eye(3, :f64))

      {:ok,
       %{
         camera: calibration(width, height, k, d, identity, projection),
         rms_px: rms,
         fx_px: hd(projection),
         samples: length(views)
       }}
    else
      {:error, message} -> {:error, "calibration failed: #{message}"}
    end
  end

  # The camera matrix of the undistorted image, as a 3 x 4 projection without translation.
  defp projection(k, d, size) do
    case Evision.getOptimalNewCameraMatrix(k, d, size, 0) do
      {:error, _} = error -> error
      {matrix, _region} -> {:ok, with_zero_column(flatten(matrix))}
    end
  end

  defp with_zero_column(matrix),
    do: matrix |> Enum.chunk_every(3) |> Enum.flat_map(&(&1 ++ [0.0]))

  @doc """
  Solves for both cameras from `samples`, the corners found in each pair of
  frames, as `VisionCore.Calibration.Chessboard.detect/2` returns them.
  `size` is the capture size in pixels.

  Returns the two calibrations, the RMS reprojection error of each camera and
  of the pair, the baseline in meters and the rectified focal length in pixels.
  """
  @spec solve(Board.t(), {pos_integer(), pos_integer()}, samples()) ::
          {:ok, result()} | {:error, String.t()}
  def solve(_board, _size, samples) when length(samples) < @min_samples do
    {:error, "at least #{@min_samples} samples are needed, got #{length(samples)}"}
  end

  def solve(%Board{} = board, {width, height} = size, samples) do
    object_points = List.duplicate(object_mat(board), length(samples))
    left_points = Enum.map(samples, &image_mat(&1.left))
    right_points = Enum.map(samples, &image_mat(&1.right))

    with {:ok, {left_rms, k1, d1}} <- calibrate(object_points, left_points, size),
         {:ok, {right_rms, k2, d2}} <- calibrate(object_points, right_points, size),
         {:ok, {stereo_rms, k1, d1, k2, d2, r, t}} <-
           stereo_calibrate(object_points, left_points, right_points, {k1, d1, k2, d2}, size),
         {:ok, {r1, r2, p1, p2}} <- rectify(k1, d1, k2, d2, size, r, t) do
      left_projection = flatten(p1)
      right_projection = flatten(p2)

      {:ok,
       %{
         left: calibration(width, height, k1, d1, r1, left_projection),
         right: calibration(width, height, k2, d2, r2, right_projection),
         left_rms_px: left_rms,
         right_rms_px: right_rms,
         stereo_rms_px: stereo_rms,
         baseline_m: -Enum.at(right_projection, 3) / Enum.at(right_projection, 0),
         fx_px: Enum.at(left_projection, 0),
         samples: length(samples)
       }}
    else
      {:error, message} -> {:error, "calibration failed: #{message}"}
    end
  end

  defp calibrate(object_points, image_points, size) do
    case Evision.calibrateCamera(
           object_points,
           image_points,
           size,
           Evision.Mat.eye(3, :f64),
           Evision.Mat.zeros({1, 5}, :f64),
           flags: Evision.Constant.cv_CALIB_FIX_K3()
         ) do
      {rms, k, d, _rvecs, _tvecs} -> {:ok, {rms, k, d}}
      {:error, _} = error -> error
    end
  end

  defp stereo_calibrate(object_points, left_points, right_points, {k1, d1, k2, d2}, size) do
    case Evision.stereoCalibrate(object_points, left_points, right_points, k1, d1, k2, d2, size,
           flags: Evision.Constant.cv_CALIB_FIX_INTRINSIC(),
           criteria: {Evision.Constant.cv_EPS() + Evision.Constant.cv_MAX_ITER(), 1, 1.0e-5}
         ) do
      {:error, _} = error ->
        error

      # The essential and fundamental matrices follow, then the per-view errors where OpenCV gives them.
      solved when tuple_size(solved) >= 7 ->
        [rms, k1, d1, k2, d2, r, t | _rest] = Tuple.to_list(solved)
        {:ok, {rms, k1, d1, k2, d2, r, t}}
    end
  end

  defp rectify(k1, d1, k2, d2, size, r, t) do
    case Evision.stereoRectify(k1, d1, k2, d2, size, r, t,
           flags: Evision.Constant.cv_CALIB_ZERO_DISPARITY(),
           alpha: 0
         ) do
      {r1, r2, p1, p2, _q, _roi1, _roi2} -> {:ok, {r1, r2, p1, p2}}
      {:error, _} = error -> error
    end
  end

  defp calibration(width, height, k, d, r, p) do
    %CameraCalibration{
      width: width,
      height: height,
      distortion_model: "plumb_bob",
      distortion_coefficients: flatten(d),
      camera_matrix: flatten(k),
      rectification_matrix: flat(r),
      projection_matrix: p
    }
  end

  defp object_mat(board) do
    board
    |> Board.object_points()
    |> Enum.map(&Tuple.to_list/1)
    |> Nx.tensor(type: :f32)
    |> Evision.Mat.from_nx()
  end

  defp image_mat(corners) do
    corners
    |> Enum.map(&Tuple.to_list/1)
    |> Nx.tensor(type: :f32)
    |> Evision.Mat.from_nx()
  end

  defp flat(list) when is_list(list), do: list
  defp flat(mat), do: flatten(mat)

  defp flatten(mat) do
    mat
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f64)
    |> Nx.to_flat_list()
  end
end
