defmodule VmsApi.CarControlsDispatcher do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    VmsCore.Controllers.ControlsController.subscribe(self())
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:updated, payload}, state) do
    VmsApiWeb.Endpoint.broadcast!("car-controls", "update", payload)
    {:noreply, state}
  end
end
