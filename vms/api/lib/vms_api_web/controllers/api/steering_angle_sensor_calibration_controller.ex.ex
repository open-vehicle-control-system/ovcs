defmodule VmsApiWeb.Api.SteeringAngleSensorCalibrationController do
  use VmsApiWeb, :controller

  def create(conn, _params) do
    :ok = VmsCore.Components.Bosch.LWS.calibrate_angle_0()
    conn
    |> put_status(:ok)
    |> render("create.json", %{})
  end
end
