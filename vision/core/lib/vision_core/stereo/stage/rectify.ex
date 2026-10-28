defmodule VisionCore.Stereo.Stage.Rectify do
  @moduledoc """
  Undistorts and rectifies both images, so a point lies on the same row
  in each. The look-up tables are built once from each camera's
  calibration (K, D, R, P) with `Evision.initUndistortRectifyMap/6`; at
  runtime it is one `Evision.remap/4` per image.

  Leave it out of the stage list when the frames are already rectified.
  """
  @behaviour VisionCore.Stereo.Stage

  alias VisionCore.Ros2.CameraCalibration
  alias VisionCore.Stereo.Pair

  @impl VisionCore.Stereo.Stage
  def init(_opts, context) do
    {:ok,
     %{
       left: rectification_maps(context.left_calibration),
       right: rectification_maps(context.right_calibration)
     }}
  end

  @impl VisionCore.Stereo.Stage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.Stage
  def provides, do: [:left, :right, :rectification_map_left]

  @impl VisionCore.Stereo.Stage
  def run(%Pair{} = pair, %{left: left_maps, right: right_maps} = state) do
    {left_map_x, _left_map_y} = left_maps

    {:ok,
     %{
       pair
       | left: remap(pair.left, left_maps),
         right: remap(pair.right, right_maps),
         # CV_16SC2: map_x holds both axes; see `VisionCore.Detection.Fusion.remap/4`.
         rectification_map_left: left_map_x
     }, state}
  end

  defp remap(image, {map_x, map_y}),
    do: Evision.remap(image, map_x, map_y, Evision.Constant.cv_INTER_LINEAR())

  # Undistortion plus the rectifying rotation.
  defp rectification_maps(%CameraCalibration{} = calibration) do
    Evision.initUndistortRectifyMap(
      matrix_3x3(calibration.camera_matrix),
      distortion_vector(calibration.distortion_coefficients),
      matrix_3x3(calibration.rectification_matrix),
      projection_matrix_to_camera_matrix(calibration.projection_matrix),
      {calibration.width, calibration.height},
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
end
