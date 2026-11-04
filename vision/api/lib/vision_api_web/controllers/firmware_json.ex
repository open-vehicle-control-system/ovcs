defmodule VisionApiWeb.FirmwareJSON do
  @moduledoc """
  `OvcsVehicle.FirmwareInfo` as a `firmwares` singleton: `revision`, `target`,
  `nervesSystem` with `nervesSystemVersion`, `nil` on a host, and `vehicle`,
  `nil` without `VEHICLE`.
  """
  alias VisionApiWeb.JsonApi
  alias OvcsVehicle.FirmwareInfo

  @doc "The `current` firmware."
  @spec show(%{firmware: FirmwareInfo.t()}) :: map()
  def show(%{firmware: %FirmwareInfo{} = firmware}) do
    %{
      data:
        JsonApi.resource("firmwares", "current", %{
          revision: firmware.revision,
          target: firmware.target,
          nervesSystem: firmware.nerves_system,
          nervesSystemVersion: firmware.nerves_system_version,
          vehicle: firmware.vehicle
        })
    }
  end
end
