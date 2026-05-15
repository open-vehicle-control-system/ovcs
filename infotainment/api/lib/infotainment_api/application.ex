defmodule InfotainmentApi.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      InfotainmentApiWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:infotainment_api, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: InfotainmentApi.PubSub},
      InfotainmentApiWeb.Endpoint
    ]

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
end
