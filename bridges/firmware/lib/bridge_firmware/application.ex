defmodule BridgeFirmware.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = host_only() ++ [{OvcsBridge.Supervisor, []}]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: BridgeFirmware.Supervisor
    )
  end

  # On host (`./ovcs run`) stop nerves_uevent — its netlink port
  # crash-loops on a dev host's coldplug uevents and isn't used off
  # target. See `OvcsVehicle.HostUEventGuard`.
  defp host_only do
    if Nerves.Runtime.mix_target() == :host, do: [OvcsVehicle.HostUEventGuard], else: []
  end
end
