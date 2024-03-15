defmodule VmsApiWeb.Api.VehicleStateJSON do
  use VmsApiWeb, :view

  def render("vehicle_state.json",%{selected_gear: selected_gear, speed: speed, key_status: key_status}) do
    %{
      type: "vehicleState",
      id:    "vehicleState",
      attributes: %{
        selectedGear: selected_gear,
        speed: speed,
        keyStatus: key_status
      }
    }
  end
end
