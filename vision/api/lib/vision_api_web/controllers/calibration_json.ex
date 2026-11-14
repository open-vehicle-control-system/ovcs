defmodule VisionApiWeb.CalibrationJSON do
  @moduledoc """
  A calibration in use, as a `calibrations` JSON:API resource, and the
  calibration session's state, as the `calibration-*` action resources
  and the `calibration` channel carry it. Both shapes are shared by the
  controllers and the channel.

  A calibration has its `kind`, `stereo`, `camera` or `pose`, its
  `source` (`builtIn`, `stored` or `none`), `storedAt`, `canReset`, its
  `cameras`, each with its `name`, the `file` to save its `yaml` under,
  its image size, intrinsics and distortion, for a stereo pair
  `baselineM` and `rectifiedFx`, `null` otherwise, for a pose its `pose`,
  `null` otherwise or without one, and its `error`, why a file gives no
  calibration. A pose's cameras are the stereo left camera's and the
  camera's calibrations it is measured with.

  A session has its `phase`, `board`, `samples`, `progress`, `goodEnough`,
  its last `detection`, the corners found in each camera's frame as
  fractions of it, its `result` once solved, with the image size it is
  for, and its `error`.

  A pose has its `rotation`, row-major, its `translation` in metres, the
  `distanceMm` between the two cameras, and the `file` to save its
  `yaml` under; a solved one also its `rmsPx`.
  """
  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Calibration
  alias VisionCore.Camera.Pose
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
      error: in_use.error,
      baselineM: in_use.baseline_m,
      rectifiedFx: rectified_fx(in_use),
      cameras: Enum.map(in_use.cameras, &camera/1),
      pose: pose_in_use(in_use.pose)
    }
  end

  defp pose_in_use(nil), do: nil
  defp pose_in_use(%{pose: pose, file: file, yaml: yaml}), do: pose(pose, file, yaml)

  @doc "The attributes of `pose`, saved under `file` as `yaml`."
  @spec pose(Pose.t(), String.t(), String.t()) :: map()
  def pose(%Pose{} = pose, file, yaml),
    do: %{
      rotation: pose.rotation,
      translation: pose.translation,
      distanceMm: Pose.distance_m(pose) * 1000,
      file: file,
      yaml: yaml
    }

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
      imageWidth: result.left.width,
      imageHeight: result.left.height,
      cameras: [
        solved("left", "#{prefix}_left", result.left, result.left_rms_px),
        solved("right", "#{prefix}_right", result.right, result.right_rms_px)
      ],
      stereoRmsPx: result.stereo_rms_px,
      baselineM: result.baseline_m,
      fxPx: result.fx_px,
      samples: result.samples,
      pose: nil
    }

  defp result(result, %{kind: :camera, id: name}),
    do: %{
      imageWidth: result.camera.width,
      imageHeight: result.camera.height,
      cameras: [solved(name, name, result.camera, result.rms_px)],
      stereoRmsPx: nil,
      baselineM: nil,
      fxPx: result.fx_px,
      samples: result.samples,
      pose: nil
    }

  # The session names its target by id: its camera's name comes from the configuration.
  defp result(result, %{kind: :pose, id: id}) do
    {:ok, %{name: name}} = Calibration.fetch_target(CalibrationUnit.config(), id)
    file = Calibration.pose_file(name)

    %{
      imageWidth: nil,
      imageHeight: nil,
      cameras: [],
      stereoRmsPx: nil,
      baselineM: nil,
      fxPx: nil,
      samples: result.samples,
      pose: Map.put(pose(result.pose, file, Pose.to_yaml(result.pose)), :rmsPx, result.rms_px)
    }
  end

  defp solved(name, file, calibration, rms_px),
    do: %{
      name: name,
      file: "#{file}.yaml",
      rmsPx: rms_px,
      yaml: CameraCalibration.to_yaml(calibration, file)
    }
end
