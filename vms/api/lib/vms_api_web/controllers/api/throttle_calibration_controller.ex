defmodule VmsApiWeb.Api.ThrottleCalibrationController do
  use VmsApiWeb, :controller

  def show(conn, _params) do
    {:ok, car_controls} = VmsCore.Controllers.ControlsController.car_controls_state()
    conn
    |> put_status(:ok)
    |> render("show.json", %{throttle_calibration_status: car_controls.throttle_calibration_status})
  end

  def create(conn, %{"calibrationModeEnabled" => true} = _params) do
    :ok = VmsCore.Controllers.ControlsController.enable_throttle_calibration_mode()
    {:ok, car_controls} = VmsCore.Controllers.ControlsController.car_controls_state()
    conn
    |> put_status(:ok)
    |> render("create.json", %{throttle_calibration_status: car_controls.throttle_calibration_status})
  end

  def create(conn, %{"calibrationModeEnabled" => false} = _params) do
    :ok = VmsCore.Controllers.ControlsController.disable_throttle_calibration_mode()
    {:ok, car_controls} = VmsCore.Controllers.ControlsController.car_controls_state()
    conn
    |> put_status(:ok)
    |> render("create.json", %{throttle_calibration_status: car_controls.throttle_calibration_status})
  end
end
