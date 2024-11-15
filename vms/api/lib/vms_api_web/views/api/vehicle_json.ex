defmodule VmsApiWeb.Api.VehicleJSON do
  use VmsApiWeb, :view

  def render("show.json", %{dashboard_features: dashboard_features}) do
    %{
      type: "vehicle",
      id:    "vehicle",
      attributes: %{
        networks: dashboard_features.networks,
        throttle: dashboard_features.throttle,
        steering: dashboard_features.steering,
        braking: dashboard_features.braking,
        gear: dashboard_features.gear,
        energy: dashboard_features.energy
      }
    }
  end
end
