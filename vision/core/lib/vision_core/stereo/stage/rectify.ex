defmodule VisionCore.Stereo.Stage.Rectify do
  @moduledoc """
  Undistorts and rectifies both camera frames with `NxStereo.Rectify`,
  so a point lies on the same row in each, and shrinks frames larger
  than the pipeline's size in the same pass, with one bilinear sample
  per pixel. Each camera's calibration is an input, so a reloaded
  calibration needs no new compiled module.

  ## Options

    * `:right_row_offset` (`0.0`) — rows the right image is moved by, a
      correction for cameras that have shifted since the calibration
      (`VisionCore.Stereo.AlignmentCorrection` sets it); also a runtime
      setting.
  """
  @behaviour VisionCore.Stereo.NxStage

  alias VisionCore.Ros2.CameraCalibration

  @max_row_offset 8

  @option_specs [
    right_row_offset: %{
      type: :double,
      range: {-@max_row_offset, @max_row_offset},
      description: "Rows the right image is moved by to line up with the left one"
    }
  ]

  @impl VisionCore.Stereo.NxStage
  def init(opts, context) do
    state = %{size: {context.height, context.width}, right_row_offset: 0.0}
    set_option(state, :right_row_offset, Keyword.get(opts, :right_row_offset, 0.0))
  end

  @impl VisionCore.Stereo.NxStage
  def requires, do: [:left_frame, :right_frame]

  @impl VisionCore.Stereo.NxStage
  def provides, do: [:left, :right]

  @impl VisionCore.Stereo.NxStage
  def params(state, context) do
    right = context.right_calibration |> camera() |> move_rows(state.right_row_offset)
    %{left: camera(context.left_calibration), right: right}
  end

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

  @impl VisionCore.Stereo.NxStage
  def option_specs, do: @option_specs

  @impl VisionCore.Stereo.NxStage
  def options(state), do: %{right_row_offset: state.right_row_offset}

  @impl VisionCore.Stereo.NxStage
  def set_option(state, :right_row_offset, rows)
      when is_number(rows) and abs(rows) <= @max_row_offset,
      do: {:ok, %{state | right_row_offset: rows * 1.0}}

  def set_option(_state, :right_row_offset, rows),
    do: {:error, "right_row_offset is at most #{@max_row_offset} rows, got #{inspect(rows)}"}

  # Sampling row v + rows: the inverse projection's row column, times rows, joins its constant one.
  defp move_rows(camera, rows) do
    inverse = camera.inverse_pr
    constant = Nx.add(inverse[[.., 2]], Nx.multiply(rows, inverse[[.., 1]]))
    %{camera | inverse_pr: Nx.put_slice(inverse, [0, 2], Nx.reshape(constant, {3, 1}))}
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
