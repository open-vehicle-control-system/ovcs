defmodule VisionApiWeb.CalibrationController do
  @moduledoc """
  The stereo calibration in use, a `calibrations` singleton identified by
  the unit's prefix (`VisionCore.Stereo.Calibration.in_use/1`). A unit
  without a `:stereo` component has none: 404.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Stereo.Calibration

  def show(conn, _params) do
    with {:ok, config, _prefix} <- CalibrationUnit.fetch(),
         {:ok, in_use} <- Calibration.in_use(config) do
      render(conn, :show, in_use: in_use)
    else
      :error ->
        JsonApi.error(
          conn,
          404,
          "Not Found",
          "the unit has no stereo cameras: no :stereo component"
        )

      {:error, reason} ->
        JsonApi.error(conn, 503, "Calibration unavailable", reason)
    end
  end
end
