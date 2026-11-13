defmodule VisionApiWeb.CalibrationJSON do
  @moduledoc """
  A calibration in use, as a `calibrations` JSON:API resource, and the
  calibration session's state, as the `calibration-*` action resources
  and the `calibration` channel carry it. Both shapes are shared by the
  controllers and the channel.

  A calibration has its `kind`, `stereo` or `camera`, its `source`
  (`builtIn`, `stored` or `none`), `storedAt`, `canReset`, its `cameras`,
  each with its `name`, the `file` to save its `yaml` under, its image
  size, intrinsics and distortion, and for a stereo pair `baselineM` and
  `rectifiedFx`, `null` for a camera.

  A session has its `phase`, `board`, `samples`, `progress`, `goodEnough`,
  its last `detection`, the corners found in each camera's frame as
  fractions of it, its `result` once solved and its `error`.
  """
  alias VisionApiWeb.JsonApi
  alias VisionCore.Ros2.CameraCalibration

  @doc "The `calibrations` resources of `calibrations`, each from `VisionCore.Calibration.in_use/2`."
  @spec index(%{calibrations: [VisionCore.Calibration.in_use()]}) :: map()
  def index(%{calibrations: calibrations}), do: %{data: Enum.map(calibrations, &data/1)}

  @doc "The `calibrations` resource of `in_use`."
  @spec show(%{in_use: VisionCore.Calibration.in_use()}) :: map()
  def show(%{in_use: in_use}), do: %{data: data(in_use)}

  defp data(in_use), do: JsonApi.resource("calibrations", in_use.id, in_use(in_use))

  @doc "The attributes of a calibration in use."
  @spec in_use(VisionCore.Calibration.in_use()) :: map()
  def in_use(in_use) do
    %{
      kind: Atom.to_string(in_use.kind),
      source: source(in_use.source),
      storedAt: in_use.stored_at && DateTime.to_iso8601(in_use.stored_at),
      canReset: in_use.can_reset,
      baselineM: in_use.baseline_m,
      rectifiedFx: rectified_fx(in_use),
      cameras: Enum.map(in_use.cameras, &camera/1)
    }
  end

  @doc "The attributes of the session `state` of `VisionCore.Calibration.Session`."
  @spec session(VisionCore.Calibration.Session.state()) :: map()
  def session(state) do
    %{
      phase: Atom.to_string(state.phase),
      board: board(state.board),
      samples: state.samples,
      progress: state.progress,
      goodEnough: state.good_enough,
      detection: detection(state.detection),
      result: result(state.result, state.target),
      error: state.error
    }
  end

  defp source(:built_in), do: "builtIn"
  defp source(source), do: Atom.to_string(source)

  defp camera(%{calibration: nil} = camera),
    do: %{
      name: camera.name,
      file: camera.file,
      imageWidth: nil,
      imageHeight: nil,
      fx: nil,
      fy: nil,
      cx: nil,
      cy: nil,
      distortion: nil,
      yaml: camera.yaml
    }

  defp camera(%{calibration: calibration} = camera) do
    [fx, _, cx, _, fy, cy | _rest] = calibration.camera_matrix

    %{
      name: camera.name,
      file: camera.file,
      imageWidth: calibration.width,
      imageHeight: calibration.height,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      distortion: calibration.distortion_coefficients,
      yaml: camera.yaml
    }
  end

  # The left camera's rectified focal length, the one a pair's solve gives as `fx_px`.
  defp rectified_fx(%{kind: :stereo, cameras: [%{calibration: %{} = left} | _right]}),
    do: hd(left.projection_matrix)

  defp rectified_fx(_in_use), do: nil

  defp board(nil), do: nil

  defp board(board),
    do: %{
      columns: board.columns,
      rows: board.rows,
      squareMm: Float.round(board.square_m * 1000, 3)
    }

  defp detection(nil), do: nil

  defp detection(detection) do
    views = for {camera, points} <- detection.views, do: %{camera: camera, points: points(points)}
    %{views: Enum.sort_by(views, & &1.camera), sample: detection.sample}
  end

  defp points(nil), do: nil
  defp points(points), do: for({x, y} <- points, do: [x, y])

  defp result(nil, _target), do: nil

  defp result(result, %{kind: :stereo, id: prefix}),
    do: %{
      cameras: [
        solved("left", "#{prefix}_left", result.left, result.left_rms_px),
        solved("right", "#{prefix}_right", result.right, result.right_rms_px)
      ],
      stereoRmsPx: result.stereo_rms_px,
      baselineM: result.baseline_m,
      fxPx: result.fx_px,
      samples: result.samples
    }

  defp result(result, %{kind: :camera, id: name}),
    do: %{
      cameras: [solved(name, name, result.camera, result.rms_px)],
      stereoRmsPx: nil,
      baselineM: nil,
      fxPx: result.fx_px,
      samples: result.samples
    }

  defp solved(name, file, calibration, rms_px),
    do: %{
      name: name,
      file: "#{file}.yaml",
      rmsPx: rms_px,
      yaml: CameraCalibration.to_yaml(calibration, file)
    }
end
