defmodule VisionApiWeb.CalibrationController do
  @moduledoc """
  The calibrations in use, read-only: one `calibrations` resource per
  target the unit can calibrate (`VisionCore.Calibration`), its stereo
  pair, identified by the stereo unit's prefix, each camera of its own,
  identified by its name, and each such camera's pose relative to the
  pair, identified as `<name>-pose`. A calibration whose file cannot be
  read is still a resource, with its `error`.
  """
  use VisionApiWeb, :controller

  alias VisionApiWeb.{CalibrationUnit, JsonApi}
  alias VisionCore.Calibration

  def index(conn, _params) do
    config = CalibrationUnit.config()

    calibrations =
      for target <- CalibrationUnit.targets(),
          {:ok, in_use} <- [Calibration.in_use(config, target.id)],
          do: in_use

    render(conn, :index, calibrations: calibrations)
  end

  def show(conn, %{"id" => id}) do
    case Calibration.in_use(CalibrationUnit.config(), id) do
      {:ok, in_use} ->
        render(conn, :show, in_use: in_use)

      {:error, :not_found} ->
        JsonApi.error(conn, 404, "no calibration #{id}")

      {:error, reason} ->
        JsonApi.error(conn, 503, reason, title: "Calibration unavailable")
    end
  end
end
