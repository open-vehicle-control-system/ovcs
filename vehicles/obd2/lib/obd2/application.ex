defmodule Obd2.Application do
  @moduledoc """
  Local-dev Application for OBD2. Installed only when
  `Mix.target() == :host`.
  """
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{OvcsVehicle.LocalSupervisor, Obd2}],
      strategy: :one_for_one,
      name: __MODULE__.Supervisor
    )
  end
end
