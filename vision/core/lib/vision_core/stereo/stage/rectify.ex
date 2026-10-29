defmodule VisionCore.Stereo.Stage.Rectify do
  @moduledoc """
  Undistorts and rectifies both images with `NxStereo.Rectify`, so a
  point lies on the same row in each. Each camera's calibration is an
  input, so a reloaded calibration needs no new compiled module.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Ros2.CameraCalibration

  @impl VisionCore.Stereo.NxStage
  def init(_opts, _context), do: {:ok, nil}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def params(_state, context),
    do: %{left: camera(context.left_calibration), right: camera(context.right_calibration)}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, _state) do
    tensors
    |> Map.put(:left, NxStereo.Rectify.rectify(tensors.left, params.left))
    |> Map.put(:right, NxStereo.Rectify.rectify(tensors.right, params.right))
  end

  defp camera(%CameraCalibration{} = calibration) do
    NxStereo.Rectify.camera(
      calibration.camera_matrix,
      calibration.distortion_coefficients,
      calibration.rectification_matrix,
      calibration.projection_matrix
    )
  end
end
