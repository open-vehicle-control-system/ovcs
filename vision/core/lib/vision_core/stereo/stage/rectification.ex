defmodule VisionCore.Stereo.Stage.Rectification do
  @moduledoc """
  Undistorts and rectifies both camera frames with `NxStereo.Rectify`,
  so a point lies on the same row in each, and shrinks frames larger
  than the pipeline's size in the same pass, with one bilinear sample
  per pixel; it refuses to start on frames smaller than that size. Each
  camera's calibration is an input, so a reloaded calibration needs no
  new compiled module.

  ## Options

    * `:right_row_offset` (`0.0`) — rows the right image is moved by, up
      to 8 either way, a correction for cameras that have shifted since
      the calibration (`VisionCore.Stereo.AlignmentCorrection` sets it);
      also a runtime setting.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Parameters.Check
  alias VisionCore.Ros2.CameraCalibration

  @max_row_offset 8

  @option_specs [
    right_row_offset: %{
      type: :double,
      range: {-@max_row_offset, @max_row_offset},
      description: "Rows the right image is moved by to line up with the left one"
    }
  ]

  @defaults %{right_row_offset: 0.0}

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

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    with {:ok, settings} <- Check.init_settings(@option_specs, @defaults, opts),
         do: NxStereo.Stage.Rectification.init(Map.to_list(settings), context)
  end

  @impl VisionCore.Stereo.NxStage
  def stereo_stage, do: NxStereo.Stage.Rectification

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left_frame, :right_frame]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  defdelegate native_kind, to: NxStereo.Stage.Rectification

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

  @impl VisionCore.Stereo.NxStage
  defdelegate step(tensors, params, state), to: NxStereo.Stage.Rectification

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{right_row_offset: state.right_row_offset}

  @impl VisionCore.Stereo.NxStage
  def set_option(state, key, value) do
    with {:ok, value} <- Check.change_setting(@option_specs, options(state), key, value),
         do: {:ok, %{state | key => value}}
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
