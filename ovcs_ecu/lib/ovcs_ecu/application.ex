defmodule OvcsEcu.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    _vehicle_config = vehicle_config()
    children = [
      {OvcsEcu.NissanLeaf.Em57.Charger, []},
      {OvcsEcu.OvcsControllers.CarControlsController, []},
      {OvcsEcu.OvcsControllers.ContactorsController, []},
      {OvcsEcu.OvcsControllers.VmsController, []},
      {OvcsEcu.VwPolo.IgnitionLock, []},
      {OvcsEcu.NissanLeaf.Em57.Inverter, []},
      {OvcsEcu.BatteryManagementSystem, []},
      {OvcsEcu.Charger, []},
      {OvcsEcu.IgnitionLock, []},
      {OvcsEcu.Inverter, []},
      {OvcsEcu.Vehicle, []}
    ]

    opts = [strategy: :one_for_one, name: OvcsEcu.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp vehicle_config() do
    vehicle = Application.get_env(:ovcs_ecu, :vehicle)
    config_path =  Path.join(:code.priv_dir(:ovcs_ecu), "vehicles/#{vehicle}.json")
    Jason.decode!(File.read!(config_path))
  end
end
