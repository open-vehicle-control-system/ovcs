defmodule VisionCore.Calibration.Solver do
  @moduledoc """
  Computes a calibration from chessboard corner samples: a stereo pair's,
  or one camera's.

  Each camera is calibrated on its own (`plumb_bob`, `k3` fixed at 0). A
  pair is then solved for its relative pose with the intrinsics held fixed,
  and rectified with alpha 0 and zero disparity. A camera alone keeps an
  identity rectification, and its projection is its camera matrix refitted
  to the undistorted image with alpha 0. The results match what
  `cameracalibrator` writes, so the calibrations load like any other.
  """

  alias VisionCore.Calibration.Board
  alias VisionCore.Ros2.CameraCalibration

  @min_samples 3

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
