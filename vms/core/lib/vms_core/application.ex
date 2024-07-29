defmodule VmsCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:vms_core, :load_debugger_dependencies) do
      load_debugger_dependencies()
    end

    children = [
      VmsCore.Repo,
      {Ecto.Migrator,
        repos: Application.fetch_env!(:vms_core, :ecto_repos),
        skip: skip_migrations?()},
      {VmsCore.VwPolo.Engine, []},
      {VmsCore.Controllers.ControlsController, []},
      {VmsCore.VwPolo.Abs, []},
      {VmsCore.VwPolo.PassengerCompartment, []},
      {VmsCore.VwPolo.IgnitionLock, []},
      {VmsCore.NissanLeaf.Em57.Charger, []},
      {VmsCore.Orion.Bms2, []},
      {VmsCore.NissanLeaf.Em57.Inverter, []},
      {VmsCore.BatteryManagementSystem, []},
      {VmsCore.Charger, []},
      {VmsCore.Abs, []},
      {VmsCore.PassengerCompartment, []},
      {VmsCore.IgnitionLock, []},
      {VmsCore.Inverter, []},
      {VmsCore.Vehicle, []},
      {VmsCore.NetworkInterfacesMonitor, []},
      {VmsCore.Status, []},
      {VmsCore.Infotainment, []},
      {VmsCore.Bosch.IboosterGen2, []},
      {VmsCore.Controllers.Configuration, []},
      {VmsCore.Controllers.FrontController, []},
      {VmsCore.Controllers.RearController, []}
    ]

    opts = [strategy: :one_for_one, name: VmsCore.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end

  defp load_debugger_dependencies do
    Mix.ensure_application!(:wx)
    Mix.ensure_application!(:runtime_tools)
    Mix.ensure_application!(:observer)
  end
end
