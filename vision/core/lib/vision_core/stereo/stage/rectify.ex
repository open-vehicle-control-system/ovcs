defmodule VisionCore.Stereo.Stage.Rectify do
  @moduledoc """
  Undistorts and rectifies both camera frames with `NxStereo.Rectify`,
  so a point lies on the same row in each, and shrinks frames larger
  than the pipeline's size in the same pass, with one bilinear sample
  per pixel. Each camera's calibration is an input, so a reloaded
  calibration needs no new compiled module.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Ros2.CameraCalibration

  @impl VisionCore.Stereo.NxStage
  def init(_opts, context), do: {:ok, %{size: {context.height, context.width}}}

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left_frame, :right_frame]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def params(_state, context),
    do: %{left: camera(context.left_calibration), right: camera(context.right_calibration)}

  @impl VisionCore.Stereo.NxStage
  def step(tensors, params, %{size: size}) do
    tensors
    |> Map.put(
      :left,
      NxStereo.Rectify.rectify(tensors.left_frame, params.left, size: size)
    )
    |> Map.put(
      :right,
      NxStereo.Rectify.rectify(tensors.right_frame, params.right, size: size)
    )
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
