defmodule InfotainmentApiWeb.Api.VehicleController do
  use InfotainmentApiWeb, :controller

  def show(conn, _params) do
    vehicle_composer = InfotainmentCore.Application.vehicle_composer()
    vehicle = vehicle_composer.infotainment_configuration().vehicle

    conn
    |> put_status(:ok)
    |> render("show.json", %{vehicle: vehicle})
  end
end
