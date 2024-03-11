defmodule Cantastic.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Cantastic.ConfigurationStore, []},
      {DynamicSupervisor, name: Cantastic.DynamicSupervisor, strategy: :one_for_one},
      {Cantastic.Socketcand, []},
      {Cantastic.DynamicInitializer, []}
    ]

    opts = [strategy: :one_for_one, name: Cantastic.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
