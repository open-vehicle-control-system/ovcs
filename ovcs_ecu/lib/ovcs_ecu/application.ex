defmodule OvcsEcu.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    _vehicle_config = vehicle_config()
    children = [
      {OvcsEcu.BatteryManagementSystem, []},
      {OvcsEcu.Charger, []},
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
