defmodule VmsApiWeb.Api.SteeringAngleSensorCalibrationController do
  use VmsApiWeb, :controller

  def create(conn, _params) do
    :ok = VmsCore.Bosch.Lws.calibrate_angle_0()
    conn
    |> put_status(:ok)
    |> render("create.json", %{steering_angle_sensor_calibration_status: :ok})
  end
end
