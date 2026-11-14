defmodule VisionApiWeb.SavedCalibrationJSON do
  @moduledoc """
  A calibration the unit keeps (`VisionCore.Calibration.Saved`) as a
  `saved-calibrations` JSON:API resource: its `name`, its `origin`
  (`dashboard` or `imported`), `createdAt`, whether it is `inForce`, the
  `board`, the `samples` and the `stereoRmsPx` of the session that solved
  it, `null` for one the unit did not solve, a pair's `baselineM`, and
  its `cameras`, each with its `name`, image size, intrinsics, distortion
  coefficients and `rmsPx`. Its `calibration` relationship names the
  target it calibrates, one of the `calibrations`.
  """
  alias VisionApiWeb.JsonApi

  @distortion [:k1, :k2, :p1, :p2, :k3]

  @doc "The `saved-calibrations` resources of `kept`, each from `VisionCore.Calibration.saved/2`."
  @spec index(%{kept: [VisionCore.Calibration.kept()]}) :: map()
  def index(%{kept: kept}), do: %{data: Enum.map(kept, &data/1)}

  @doc "The `saved-calibrations` resource of `kept`."
  @spec show(%{kept: VisionCore.Calibration.kept()}) :: map()
  def show(%{kept: kept}), do: %{data: data(kept)}

  defp data(%{saved: saved, in_force: in_force}) do
    JsonApi.resource(
      "saved-calibrations",
      Integer.to_string(saved.id),
      %{
        name: saved.name,
        origin: saved.origin,
        createdAt: DateTime.to_iso8601(saved.inserted_at),
        inForce: in_force,
        board: board(saved),
        samples: saved.samples,
        stereoRmsPx: saved.stereo_rms_px,
        baselineM: saved.baseline_m,
        cameras: Enum.map(saved.cameras, &camera/1)
      },
      %{calibration: JsonApi.to_one("calibrations", saved.target)}
    )
  end

  defp board(%{board_columns: nil}), do: nil

  defp board(saved),
    do: %{
      columns: saved.board_columns,
      rows: saved.board_rows,
      squareMm: Float.round(saved.board_square_m * 1000, 3)
    }

  defp camera(camera),
    do: %{
      name: camera.name,
      imageWidth: camera.image_width,
      imageHeight: camera.image_height,
      fx: camera.fx,
      fy: camera.fy,
      cx: camera.cx,
      cy: camera.cy,
      distortion: Enum.map(@distortion, &Map.fetch!(camera, &1)),
      rmsPx: camera.rms_px
    }
end
