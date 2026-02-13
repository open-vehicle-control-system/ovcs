defmodule InfotainmentApiWeb.Api.Vehicle.PagesController do
  use InfotainmentApiWeb, :controller

  def index(conn, _params) do
    vehicle_composer = InfotainmentCore.Application.vehicle_composer()
    pages            = vehicle_composer.infotainment_configuration().vehicle.pages
    conn
    |> put_status(:ok)
    |> render("index.json", %{pages: pages})
  end
end
