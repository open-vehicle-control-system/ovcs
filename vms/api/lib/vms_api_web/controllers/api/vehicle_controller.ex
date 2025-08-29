defmodule VmsApiWeb.Api.VehicleController do
  use VmsApiWeb, :controller

  def show(conn, _params) do
    vehicle_composer = VmsCore.Application.vehicle_composer()
    vehicle          = vehicle_composer.dashboard_configuration().vehicle
    conn
    |> put_status(:ok)
    |> render("show.json", %{vehicle: vehicle})
  end
end
