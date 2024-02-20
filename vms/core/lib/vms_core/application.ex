defmodule VmsCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      #VmsCore.Repo,
      #{Ecto.Migrator,
      #  repos: Application.fetch_env!(:vms_core, :ecto_repos),
      #  skip: skip_migrations?()},
      {VmsCore.NissanLeaf.Em57.Charger, []},
      {VmsCore.OvcsControllers.CarControlsController, []},
      {VmsCore.OvcsControllers.ContactorsController, []},
      {VmsCore.OvcsControllers.VmsController, []},
      {VmsCore.VwPolo.IgnitionLock, []},
      {VmsCore.NissanLeaf.Em57.Inverter, []},
      {VmsCore.BatteryManagementSystem, []},
      {VmsCore.Charger, []},
      {VmsCore.IgnitionLock, []},
      {VmsCore.Inverter, []},
      {VmsCore.Vehicle, []}
    ]

    opts = [strategy: :one_for_one, name: VmsCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end
end
