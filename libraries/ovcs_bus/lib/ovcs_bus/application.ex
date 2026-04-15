defmodule OvcsBus.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: OvcsBus}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OvcsBus.Supervisor)
  end
end
