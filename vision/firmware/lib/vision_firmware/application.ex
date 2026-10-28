defmodule VisionFirmware.Application do
  @moduledoc false
  use Application

  # The pipeline lives in `VisionCore.Application` and `VisionApi.Application`.
  @impl Application
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: VisionFirmware.Supervisor)
  end

  # See `OvcsVehicle.HostUEventGuard` and `OvcsVehicle.FirmwareValidator`.
  defp children do
    if Nerves.Runtime.mix_target() == :host,
      do: [OvcsVehicle.HostUEventGuard],
      else: [OvcsVehicle.FirmwareValidator]
  end
end
