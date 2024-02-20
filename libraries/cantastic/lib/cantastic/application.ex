defmodule Cantastic.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Cantastic.Interface

  @impl true
  def start(_type, _args) do
    opts = [strategy: :one_for_one, name: Cantastic.ConfigurationSupervisor]
    Supervisor.start_link([{Cantastic.ConfigurationStore, []}], opts)
    IO.inspect "*******"
    children = Interface.configure_children()
    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Cantastic.InterfaceSupervisor]
    Supervisor.start_link(children, opts)
  end
end
