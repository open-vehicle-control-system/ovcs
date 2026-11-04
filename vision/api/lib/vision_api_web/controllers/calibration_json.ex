defmodule VisionApiWeb.CalibrationJSON do
  @moduledoc """
  The stereo calibration in use, as a `calibrations` JSON:API resource, and
  the calibration session state, as the `calibration-*` action resources
  and the `calibration` channel push it. Both shapes are shared by the
  controllers and the channel.
  """
  alias VisionApiWeb.JsonApi
  alias VisionCore.Ros2.CameraCalibration

  @doc "The `calibrations` resource of `in_use`, from `VisionCore.Stereo.Calibration.in_use/1`."
  @spec show(%{in_use: VisionCore.Stereo.Calibration.in_use()}) :: map()
  def show(%{in_use: in_use}),
    do: %{data: JsonApi.resource("calibrations", in_use.prefix, in_use(in_use))}

  @doc "The attributes of the calibration in use."
  @spec in_use(VisionCore.Stereo.Calibration.in_use()) :: map()
  def in_use(in_use) do
    %{
      source: source(in_use.source),
      storedAt: in_use.stored_at && DateTime.to_iso8601(in_use.stored_at),
      canReset: in_use.can_reset,
      prefix: in_use.prefix,
      baselineM: in_use.baseline_m,
      rectifiedFx: rectified_fx(in_use.left),
      left: side(in_use.left),
      right: side(in_use.right)
    }
  end

  @doc """
  The attributes of the session `state` of `VisionCore.Calibration.Session`
  for the unit `prefix`, which names the YAML of a solved calibration.
  """
  @spec session(VisionCore.Calibration.Session.state(), String.t()) :: map()
  def session(state, prefix) do
    %{
      phase: Atom.to_string(state.phase),
      board: board(state.board),
      samples: state.samples,
      progress: state.progress,
      goodEnough: state.good_enough,
      detection: detection(state.detection),
      result: result(state.result, prefix),
      error: state.error
    }
  end

  defp source(:built_in), do: "builtIn"
  defp source(source), do: Atom.to_string(source)

  defp side(%{calibration: nil, yaml: yaml}),
    do: %{
      imageWidth: nil,
      imageHeight: nil,
      fx: nil,
      fy: nil,
      cx: nil,
      cy: nil,
      distortion: nil,
      yaml: yaml
    }

  defp side(%{calibration: calibration, yaml: yaml}) do
    [fx, _, cx, _, fy, cy | _rest] = calibration.camera_matrix

    %{
      imageWidth: calibration.width,
      imageHeight: calibration.height,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      distortion: calibration.distortion_coefficients,
      yaml: yaml
    }
  end

  # The left camera's rectified focal length, the one a solve's `fx_px` is.
  defp rectified_fx(%{calibration: nil}), do: nil
  defp rectified_fx(%{calibration: calibration}), do: hd(calibration.projection_matrix)

  defp board(nil), do: nil

  defp board(board),
    do: %{
      columns: board.columns,
      rows: board.rows,
      squareMm: Float.round(board.square_m * 1000, 3)
    }

  defp detection(nil), do: nil

  defp detection(detection),
    do: %{
      left: points(detection.left),
      right: points(detection.right),
      sample: detection.sample
    }

  defp points(nil), do: nil
  defp points(points), do: for({x, y} <- points, do: [x, y])

  defp result(nil, _prefix), do: nil

  defp result(result, prefix),
    do: %{
      leftRmsPx: result.left_rms_px,
      rightRmsPx: result.right_rms_px,
      stereoRmsPx: result.stereo_rms_px,
      baselineM: result.baseline_m,
      fxPx: result.fx_px,
      samples: result.samples,
      left: %{yaml: CameraCalibration.to_yaml(result.left, "#{prefix}_left")},
      right: %{yaml: CameraCalibration.to_yaml(result.right, "#{prefix}_right")}
    }
end
