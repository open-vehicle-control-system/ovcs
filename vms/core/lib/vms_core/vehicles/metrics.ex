defmodule VmsCore.Vehicles.Metrics do
  use GenServer
  alias VmsCore.Bus


  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Bus.subscribe("messages")
    {:ok, %{sources: %{}}}
  end

  @impl true
  def handle_info(%Bus.Message{name: name, value: value, source: source}, state) do
    state = case state.sources[source] do
      nil -> put_in(state, [:sources, source], %{})
      _ -> state
    end
    {:noreply, put_in(state, [:sources, source, name], value)}
  end

  @impl true
  def handle_call({:metrics, source}, _from, state) do
    {:reply, {:ok, Map.get(state.sources, source, %{})}, state}
  end

  def metrics(source) do
    GenServer.call(__MODULE__, {:metrics, source})
  end
end
