defmodule VmsCore.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    _vehicle_config = vehicle_config()
    children = [
      VmsCore.Repo,
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

  defp vehicle_config() do
    vehicle = Application.get_env(:vms_core, :vehicle)
    config_path =  Path.join(:code.priv_dir(:vms_core), "vehicles/#{vehicle}.json")
    Jason.decode!(File.read!(config_path))
  end
end
