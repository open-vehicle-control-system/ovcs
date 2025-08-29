defmodule VmsApiWeb.Api.Vehicle.PagesController do
  use VmsApiWeb, :controller

  def index(conn, _params) do
    vehicle_composer = VmsCore.Application.vehicle_composer()
    pages            = vehicle_composer.dashboard_configuration().vehicle.pages
    conn
    |> put_status(:ok)
    |> render("index.json", %{pages: pages})
  end
end
