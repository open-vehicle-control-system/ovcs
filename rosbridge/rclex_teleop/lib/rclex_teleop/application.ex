defmodule RclexTeleop.Application do
  @moduledoc false

  require Logger

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {RclexTeleop.Teleop, []}
    ]
    opts = [strategy: :one_for_one, name: RclexTeleop.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
