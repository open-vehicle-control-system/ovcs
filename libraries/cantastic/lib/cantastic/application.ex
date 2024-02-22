defmodule Cantastic.Application do
  use Application

  alias Cantastic.Interface

  @impl true
  def start(_type, _args) do
    case start_configuration() do
      {:ok, _pid} -> start_interfaces()
      {:error, error} -> {:error, error}
    end
  end

  defp start_configuration() do
    opts = [strategy: :one_for_one, name: Cantastic.ConfigurationSupervisor]
    Supervisor.start_link([{Cantastic.ConfigurationStore, []}], opts)
  end

  defp start_interfaces() do
    children = Interface.configure_children()
    opts     = [strategy: :one_for_one, name: Cantastic.InterfaceSupervisor]
    Supervisor.start_link(children, opts)
  end
end
