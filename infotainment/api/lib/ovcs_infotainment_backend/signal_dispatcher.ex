defmodule InfotainmentApi.SignalDispatcher do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    InfotainmentCore.VehicleStateManager.subscribe(self())
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:signals_updated, signals_state}, state) do
    InfotainmentApiWeb.Endpoint.broadcast!("debug-metrics", "update", signals_state)
    {:noreply, state}
  end
end
