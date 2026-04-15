defmodule Ovcs1.Application do
  @moduledoc """
  Local-dev Application for OVCS1. Installed only when
  `Mix.target() == :host`; firmware builds use `vms/firmware` /
  `infotainment/firmware` / `bridges/firmware` instead.

  Supervision tree = whatever `OvcsVehicle.LocalSupervisor`
  assembles from `Ovcs1.bridge_firmwares/0`. VMS + infotainment
  cores auto-start via their own OTP apps (transitive deps).
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{OvcsVehicle.LocalSupervisor, Ovcs1}],
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end
end
