defmodule VisionApiWeb.CalibrationSessionJSON do
  @moduledoc """
  A created calibration session, cancel, solve, apply or reset as a
  JSON:API resource of `type`, carrying the session as it is after it,
  related to the `calibration` the session works on; and the session's
  state as the `calibration` channel carries it.

  A session has its `phase`, `board`, `samples`, `progress`, `goodEnough`,
  its last `detection`, the corners found in each camera's frame as
  fractions of it, its `result` once solved, with the image size it is
  for, and its `error`. A solved pose is a `VisionApiWeb.CalibrationPose`
  with its `rmsPx`.
  """
  alias VisionApiWeb.{CalibrationPose, CalibrationUnit, JsonApi}
  alias VisionCore.Calibration
  alias VisionCore.Camera.Pose
  alias VisionCore.Ros2.CameraCalibration

  @doc "The resource of `type` and `id`, with the `session` state."
  @spec show(%{type: String.t(), id: String.t(), session: VisionCore.Calibration.Session.state()}) ::
          map()
  def show(%{type: type, id: id, session: session}) do
    relationships = %{
      calibration: JsonApi.to_one("calibrations", session.target && session.target.id)
    }

    %{data: JsonApi.resource(type, id, session(session), relationships)}
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
      pose:
        result.pose
        |> CalibrationPose.attributes(file, Pose.to_yaml(result.pose))
        |> Map.put(:rmsPx, result.rms_px)
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
