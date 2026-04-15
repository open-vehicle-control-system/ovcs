defmodule OvcsMini.Application do
  @moduledoc """
  Local-dev Application for OVCS Mini (VMS only — no infotainment
  head). Installed only when `Mix.target() == :host`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{OvcsVehicle.LocalSupervisor, OvcsMini}],
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end
end
