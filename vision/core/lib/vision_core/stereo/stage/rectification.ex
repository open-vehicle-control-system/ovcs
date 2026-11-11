defmodule VisionCore.Stereo.Stage.Rectification do
  @moduledoc """
  Undistorts and rectifies both camera frames with `NxStereo.Rectify`,
  so a point lies on the same row in each, and shrinks frames larger
  than the pipeline's size in the same pass, with one bilinear sample
  per pixel; it refuses to start on frames smaller than that size. Each
  camera's calibration is an input, so a reloaded calibration needs no
  new compiled module.

  ## Settings

  `NxStereo.Stage.Rectification.settings/0` declares them, with their defaults
  and the values they take; those of a type the vision parameters hold
  are this stage's parameters (`VisionCore.Stereo.NxStage`).

  `VisionCore.Stereo.AlignmentCorrection` sets `:right_row_offset` for
  cameras that have shifted since the calibration.
  """
  use VisionCore.Stereo.NxStage, stage: NxStereo.Stage.Rectification

  alias VisionCore.Ros2.CameraCalibration

  @impl VisionCore.Stereo.NxStage
  def summary, do: "Undistorts and rectifies both frames so a point lies on the same row in each."

  @impl VisionCore.Stereo.NxStage
  def explanation,
    do:
      "Lenses bend straight lines, and two cameras never point exactly the same way. " <>
        "Rectification undoes both with each camera's calibration, so that a point seen by " <>
        "the two cameras lands on the same row of each image, and shrinks the images to the " <>
        "matching size. Matching then only has to search along a row. If a camera shifts " <>
        "after calibration, the rows drift apart: right_row_offset moves the right image back " <>
        "into line, and auto_row_offset, when present, sets it for you from the row alignment " <>
        "measure. A camera that turned, or moved sideways, needs a new calibration. Watch Row " <>
        "alignment between the videos."

  # The cameras from the context's calibrations.
  @impl VisionCore.Stereo.NxStage
  def params(state, context) do
    geometry =
      Map.merge(context, %{
        left_camera: camera(context.left_calibration),
        right_camera: camera(context.right_calibration)
      })

    NxStereo.Stage.Rectification.params(state, geometry)
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
