defmodule OvcsBus.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: OvcsBus}
    ]

    # Phoenix.PubSub with `name: OvcsBus` auto-names its own
    # supervisor `OvcsBus.Supervisor` (via `Module.concat(name,
    # "Supervisor")`), so we can't reuse that atom here.
    Supervisor.start_link(children, strategy: :one_for_one, name: OvcsBus.RootSupervisor)
  end
end
