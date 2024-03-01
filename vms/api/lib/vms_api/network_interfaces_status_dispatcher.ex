defmodule VmsApi.NetworkInterfacesStatusDispatcher do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    VmsCore.NetworkInterfacesMonitor.subscribe(self())
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:interfaces_status_updated, payload}, state) do
    VmsApiWeb.Endpoint.broadcast!("network-interfaces", "update", payload)
    {:noreply, state}
  end
end
