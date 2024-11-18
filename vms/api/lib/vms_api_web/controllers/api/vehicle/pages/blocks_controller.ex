defmodule VmsApiWeb.Api.Vehicle.Page.BlocksController do
  use VmsApiWeb, :controller

  def index(conn, params) do
    vehicle_composer = VmsCore.Application.vehicle_compposer()
    page_id = params["page_id"]
    blocks   = vehicle_composer.dashboard_configuration().vehicle.pages[page_id].blocks
    conn
    |> put_status(:ok)
    |> render("index.json", %{blocks: blocks})
  end
end
