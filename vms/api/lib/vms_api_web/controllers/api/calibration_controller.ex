defmodule VmsApiWeb.Api.CalibrationController do
  use VmsApiWeb, :controller

  def show(conn, _params) do
    {status, calibration_data} = JSON.encode(VmsCore.Controllers.ControlsController.get_calibration_data())
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, calibration_data)
  end

  def create(conn, %{"calibrationModeEnabled" => true} = params) do
    :ok = VmsCore.Controllers.ControlsController.enable_calibration_mode()
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, "{\"calibration_status\":\"started\"}")
  end

  def create(conn, %{"calibrationModeEnabled" => false} = params) do
    :ok = VmsCore.Controllers.ControlsController.disable_calibration_mode()
    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(200, "{\"calibration_status\":\"disabled\"}")
  end
end
