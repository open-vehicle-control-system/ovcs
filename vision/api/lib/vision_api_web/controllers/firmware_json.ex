defmodule VisionApiWeb.FirmwareJSON do
  @moduledoc """
  `VisionCore.Firmware` as a `firmwares` singleton: `revision`, `target`,
  and `nervesSystem` with `nervesSystemVersion`, `nil` on a host.
  """
  alias VisionApiWeb.JsonApi
  alias VisionCore.Firmware

  @doc "The `current` firmware."
  @spec show(%{firmware: Firmware.t()}) :: map()
  def show(%{firmware: %Firmware{} = firmware}) do
    %{
      data:
        JsonApi.resource("firmwares", "current", %{
          revision: firmware.revision,
          target: firmware.target,
          nervesSystem: firmware.nerves_system,
          nervesSystemVersion: firmware.nerves_system_version
        })
    }
  end
end
