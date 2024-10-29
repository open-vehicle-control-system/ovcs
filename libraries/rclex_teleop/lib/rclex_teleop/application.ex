defmodule RclexTeleop.Application do
  @moduledoc false

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    orchestrator = Application.get_env(:rclex_teleop, :orchestrator)
    children = [
      %{
        id: RclexTeleop.Teleop,
        start: {
          RclexTeleop.Teleop,
          :start_link, [%{
            orchestrator: orchestrator
          }]
        }
      }
    ]
    opts = [strategy: :one_for_one, name: RclexTeleop.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
