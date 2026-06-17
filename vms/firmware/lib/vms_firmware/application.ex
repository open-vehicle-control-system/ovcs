defmodule VmsFirmware.Application do
  @moduledoc false
  use Application

  # The real supervision tree lives in `VmsCore.Application` (started
  # via OTP transitive deps) and `VmsApi.Application`. This module is
  # the release entry point — it only exists so the firmware has an
  # Application module to mount.
  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: VmsFirmware.Supervisor)
  end

  # On host (`./ovcs run`) stop nerves_uevent — its netlink port
  # crash-loops on a dev host's coldplug uevents and isn't used off
  # target. See `OvcsVehicle.HostUEventGuard`.
  defp children do
    if Nerves.Runtime.mix_target() == :host, do: [OvcsVehicle.HostUEventGuard], else: []
  end
end
