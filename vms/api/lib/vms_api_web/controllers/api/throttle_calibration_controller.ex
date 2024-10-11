defmodule VmsApiWeb.Api.ThrottleCalibrationController do
  use VmsApiWeb, :controller
  alias VmsCore.Components.OVCS.ThrottlePedal
  alias VmsCore.Metrics

  def show(conn, _params) do
    {:ok, %{throttle_calibration_status: throttle_calibration_status}} = Metrics.metrics(ThrottlePedal)
    conn
    |> put_status(:ok)
    |> render("show.json", %{throttle_calibration_status: throttle_calibration_status})
  end

  def create(conn, %{"calibrationModeEnabled" => true} = _params) do
    :ok = ThrottlePedal.enable_calibration_mode()
    conn
    |> put_status(:ok)
    |> render("create.json", %{throttle_calibration_status: "in_progress"})
  end

  def create(conn, %{"calibrationModeEnabled" => false} = _params) do
    :ok = ThrottlePedal.disable_calibration_mode()
    conn
    |> put_status(:ok)
    |> render("create.json", %{throttle_calibration_status: "disabled"})
  end
end
