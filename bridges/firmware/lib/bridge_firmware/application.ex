defmodule BridgeFirmware.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = target_guards() ++ [{OvcsBridge.Supervisor, []}]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BridgeFirmware.Supervisor
    )
  end

  # On host (`./ovcs run`) stop nerves_uevent — its netlink port
  # crash-loops on a dev host's coldplug uevents and isn't used off
  # target. See `OvcsVehicle.HostUEventGuard`.
  #
  # On target, mark the firmware valid so an A/B update sticks: the v2.0
  # systems revert to the previous slot on next boot otherwise. See
  # `OvcsVehicle.FirmwareValidator`.
  defp target_guards do
    if Nerves.Runtime.mix_target() == :host,
      do: [OvcsVehicle.HostUEventGuard],
      else: [OvcsVehicle.FirmwareValidator]
  end
end
