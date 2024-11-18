defmodule VmsApiWeb.Api.VehicleJSON do
  use VmsApiWeb, :view

  def render("show.json", %{vehicle: vehicle}) do
    %{
      data: render_one(vehicle, __MODULE__, "vehicle.json", as: :vehicle)
    }
  end

  def render("vehicle.json",%{vehicle: vehicle}) do
    %{
      type: "vehicle",
      id:    "vehicle",
      attributes: %{
        name: vehicle.name
      }
    }
  end
end
