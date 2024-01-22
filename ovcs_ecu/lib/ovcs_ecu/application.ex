defmodule OvcsEcu.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    vehicle_config = vehicle_config()
    children = [
      {OvcsEcu.VehicleStateManager, [vehicle_config]}
    ] ++ can_interfaces(vehicle_config)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OvcsEcu.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp can_interfaces(vehicle_config) do
    signals_spec      = vehicle_config["canSignals"]
    can_network_specs = Application.get_env(:ovcs_ecu, :can_networks) |> String.split(",", trim: true)
    manual_setup      = Application.get_env(:ovcs_ecu, :manual_setup)
    Enum.map(can_network_specs, fn (can_network_spec) ->
      [network_name, interface] = can_network_spec |> String.split(":")
      bitrate                   = vehicle_config["canNetworks"][network_name]["bitrate"]
      process_name              = Cantastic.Interface.process_name(network_name)
      Supervisor.child_spec({Cantastic.Interface, [network_name, interface, bitrate, manual_setup, signals_spec, OvcsEcu.VehicleStateManager]}, id: process_name)
    end)
  end

  defp vehicle_config() do
    vehicle = Application.get_env(:ovcs_ecu, :vehicle)
    config_path =  Path.join(:code.priv_dir(:ovcs_ecu), "vehicles/#{vehicle}.json")
    Jason.decode!(File.read!(config_path))
  end
end
