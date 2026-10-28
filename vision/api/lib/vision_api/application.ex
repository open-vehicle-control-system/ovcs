defmodule VisionApi.Application do
  @moduledoc """
  Serves the vision dashboard: its build from `priv/static`, the
  `/api/settings` endpoint and the status and preview channels, all fed by
  `vision_core`.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: VisionApi.PubSub},
      VisionApiWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: VisionApi.Supervisor)
  end

  @impl Application
  def config_change(changed, _new, removed) do
    VisionApiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
