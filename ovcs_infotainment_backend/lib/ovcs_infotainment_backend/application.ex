defmodule OvcsInfotainmentBackend.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    vehicle_config = vehicle_config()
    children = [
      OvcsInfotainmentBackendWeb.Telemetry,
      OvcsInfotainmentBackend.Repo,
      {Ecto.Migrator,
        repos: Application.fetch_env!(:ovcs_infotainment_backend, :ecto_repos),
        skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:ovcs_infotainment_backend, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: OvcsInfotainmentBackend.PubSub},
      # Start a worker by calling: OvcsInfotainmentBackend.Worker.start_link(arg)
      # {OvcsInfotainmentBackend.Worker, arg},
      # Start to serve requests, typically the last entry
      OvcsInfotainmentBackendWeb.Endpoint,
      {OvcsInfotainmentBackend.VehicleStateManager, [vehicle_config]},
      {OvcsInfotainmentBackend.SystemInformationManager, []},
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: OvcsInfotainmentBackend.Supervisor]
    supervisor = Supervisor.start_link(children, opts)
    Application.ensure_all_started(:cantastic)
    supervisor
  end

  defp vehicle_config() do
    vehicle = Application.get_env(:ovcs_infotainment_backend, :vehicle)
    config_path =  Path.join(:code.priv_dir(:ovcs_infotainment_backend), "vehicles/#{vehicle}.json")
    Jason.decode!(File.read!(config_path))
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    OvcsInfotainmentBackendWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end
end
