defmodule VmsApiWeb.Api.CalibrationController do
  use VmsApiWeb, :controller

  def show(conn, _params) do
    {:ok, car_controls} = VmsCore.Controllers.ControlsController.car_controls_state()
    conn
    |> put_status(:ok)
    |> render("show.json", %{calibration_status: car_controls.calibration_status})
  end

  def create(conn, %{"calibrationModeEnabled" => true} = _params) do
    :ok = VmsCore.Controllers.ControlsController.enable_calibration_mode()
    {:ok, car_controls} = VmsCore.Controllers.ControlsController.car_controls_state()
    conn
    |> put_status(:ok)
    |> render("create.json", %{calibration_status: car_controls.calibration_status})
  end

  def create(conn, %{"calibrationModeEnabled" => false} = _params) do
    :ok = VmsCore.Controllers.ControlsController.disable_calibration_mode()
    {:ok, car_controls} = VmsCore.Controllers.ControlsController.car_controls_state()
    conn
    |> put_status(:ok)
    |> render("create.json", %{calibration_status: car_controls.calibration_status})
  end
end
