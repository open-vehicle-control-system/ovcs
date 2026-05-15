defmodule InfotainmentApiWeb.Api.Vehicle.Page.BlocksController do
  use InfotainmentApiWeb, :controller

  def index(conn, params) do
    vehicle_composer = InfotainmentCore.Application.vehicle_composer()
    page_id = params["page_id"]
    blocks = vehicle_composer.infotainment_configuration().vehicle.pages[page_id].blocks

    conn
    |> put_status(:ok)
    |> render("index.json", %{blocks: blocks})
  end
end
