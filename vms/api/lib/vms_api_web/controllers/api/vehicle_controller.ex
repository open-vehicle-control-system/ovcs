
defmodule VmsApiWeb.Api.VehicleController do
  use VmsApiWeb, :controller

  def show(conn, _params) do
    vehicle_composer   = VmsCore.Application.vehicle_compposer()
    dashboard_features = vehicle_composer.dashboard_features()
    conn
    |> put_status(:ok)
    |> render("show.json", %{dashboard_features: dashboard_features})
  end
end
