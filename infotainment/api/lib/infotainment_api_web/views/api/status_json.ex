defmodule InfotainmentApiWeb.Api.StatusJSON do
  use InfotainmentApiWeb, :view

  def render("status.json", status) do
    %{
      type: "status",
      id:    "status",
      attributes: %{
        bms_missing: status.bms_missing,
        vms_missing: status.vms_missing,
        front_controller_missing: status.front_controller_missing,
        rear_controller_missing: status.rear_controller_missing,
        inverter_missing: status.inverter_missing,
        controls_controller_missing: status.controls_controller_missing,
        main_negative_off: status.main_negative_off,
        main_positive_off: status.main_positive_off,
        precharge_off: status.precharge_off,
      }
    }
  end
end
