defmodule InfotainmentApi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do

    unless Application.get_env(:infotainment_api, :vehicle) do
      Application.put_env(:infotainment_api, :vehicle,
        (System.get_env("VEHICLE") || "OVCS1") |> String.to_atom()
      )
    end

    children = [
      InfotainmentApiWeb.Telemetry,
      InfotainmentApi.Repo,
      {Ecto.Migrator,
        repos: Application.fetch_env!(:infotainment_api, :ecto_repos),
        skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:infotainment_api, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: InfotainmentApi.PubSub},
      # Start a worker by calling: InfotainmentApi.Worker.start_link(arg)
      # {InfotainmentApi.Worker, arg},
      # Start to serve requests, typically the last entry
      InfotainmentApiWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: InfotainmentApi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    InfotainmentApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") != nil
  end
end
