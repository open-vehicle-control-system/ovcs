defmodule InfotainmentApiWeb.Api.OBD2.StatusJSON do
  use InfotainmentApiWeb, :view

  def render("status.json", status) do
    %{
      type: "status",
      id:    "status",
      attributes: %{
        speed: status.speed,
        rotation_per_minute: status.rotation_per_minute,
        twelveVoltBatteryStatus: "0.0",
      }
    }
  end
end
