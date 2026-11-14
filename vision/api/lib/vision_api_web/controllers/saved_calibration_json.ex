defmodule VisionApiWeb.SavedCalibrationJSON do
  @moduledoc """
  A calibration the unit keeps (`VisionCore.Calibration.Library.kept/0`)
  as a `saved-calibrations` JSON:API resource, under its id
  (`VisionCore.Models.KeptCalibrationId`): its `name`, its `origin`
  (`dashboard` or `imported`), `createdAt`, whether it is `inForce`, the
  `board`, the `samples` and the `stereoRmsPx` of the session that solved
  it, `null` for one the unit did not solve, a pair's `baselineM`, and
  its `cameras`, each with its `name`, image size, intrinsics, distortion
  coefficients, `rmsPx`, and the `file` name to save its `yaml` under,
  as the calibration in use's. A camera's pose has no camera and its
  `pose`, as `VisionApiWeb.CalibrationJSON` renders one, with the
  `rmsPx` of the solve that made it; `null` for any other calibration.
  Its `calibration` relationship names the target it calibrates, one of
  the `calibrations`.
  """
  alias VisionApiWeb.{CalibrationJSON, JsonApi}
  alias VisionCore.Calibration.Library
  alias VisionCore.Models

  @distortion [:k1, :k2, :p1, :p2, :k3]

  @doc "The `saved-calibrations` resources of `kept`, each from `VisionCore.Calibration.saved/2`."
  @spec index(%{kept: [VisionCore.Calibration.kept()]}) :: map()
  def index(%{kept: kept}), do: %{data: Enum.map(kept, &data/1)}

  @doc "The `saved-calibrations` resource of `kept`."
  @spec show(%{kept: VisionCore.Calibration.kept()}) :: map()
  def show(%{kept: kept}), do: %{data: data(kept)}

  defp data(%{saved: saved, in_force: in_force, files: files}) do
    JsonApi.resource(
      "saved-calibrations",
      saved.id,
      %{
        name: saved.name,
        origin: saved.origin,
        createdAt: DateTime.to_iso8601(saved.inserted_at),
        inForce: in_force,
        board: board(saved),
        samples: saved.samples,
        stereoRmsPx: stereo_rms_px(saved),
        baselineM: baseline_m(saved),
        cameras: Enum.zip_with(Library.lenses(saved), files, &camera/2),
        pose: pose(saved, files)
      },
      %{calibration: JsonApi.to_one("calibrations", saved.target)}
    )
  end

  defp stereo_rms_px(%Models.StereoCameraCalibration{stereo_rms_px: rms_px}), do: rms_px
  defp stereo_rms_px(_saved), do: nil

  defp baseline_m(%Models.StereoCameraCalibration{baseline_m: baseline_m}), do: baseline_m
  defp baseline_m(_saved), do: nil

  defp pose(%Models.CameraPose{} = saved_pose, [%{file: file, yaml: yaml}]) do
    saved_pose
    |> Models.CameraPose.to_pose()
    |> CalibrationJSON.pose(file, yaml)
    |> Map.put(:rmsPx, saved_pose.rms_px)
  end

  defp pose(_saved, _files), do: nil

  defp board(%{board_columns: nil}), do: nil

  defp board(saved),
    do: %{
      columns: saved.board_columns,
      rows: saved.board_rows,
      squareMm: Float.round(saved.board_square_m * 1000, 3)
    }

  defp camera({name, lens}, file),
    do: %{
      name: name,
      imageWidth: lens.image_width,
      imageHeight: lens.image_height,
      fx: lens.fx,
      fy: lens.fy,
      cx: lens.cx,
      cy: lens.cy,
      distortion: Enum.map(@distortion, &Map.fetch!(lens, &1)),
      rmsPx: lens.rms_px,
      file: file.file,
      yaml: file.yaml
    }
end
