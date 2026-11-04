defmodule VmsApiWeb.Api.FirmwareJSON do
  @moduledoc """
  `OvcsVehicle.FirmwareInfo` as the `firmware` singleton: `revision`,
  `target`, `nervesSystem` with `nervesSystemVersion`, `nil` on a host, and
  `vehicle`, `nil` without `VEHICLE`.
  """
  use VmsApiWeb, :view

  def render("show.json", %{firmware: firmware}) do
    %{
      data: %{
        type: "firmware",
        id: "current",
        attributes: %{
          revision: firmware.revision,
          target: firmware.target,
          nervesSystem: firmware.nerves_system,
          nervesSystemVersion: firmware.nerves_system_version,
          vehicle: firmware.vehicle
        }
      }
    }
  end
end
