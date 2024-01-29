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
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OvcsEcu.Supervisor]
    supervisor = Supervisor.start_link(children, opts)
    Application.ensure_all_started(:cantastic)
    supervisor
  end

  defp vehicle_config() do
    vehicle = Application.get_env(:ovcs_ecu, :vehicle)
    config_path =  Path.join(:code.priv_dir(:ovcs_ecu), "vehicles/#{vehicle}.json")
    Jason.decode!(File.read!(config_path))
  end
end
