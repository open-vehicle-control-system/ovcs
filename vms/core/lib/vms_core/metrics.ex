defmodule VmsCore.Metrics do
  use GenServer
  alias VmsCore.PubSub

  @impl true
  def init(_) do
    PubSub.subscribe("metrics")
    {:ok, %{
      rotation_per_minute: 0
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info(%PubSub.MetricMessage{name: name, value: value}, state) do
    {:noreply, %{state | name => value}}
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def current() do
    GenServer.call(__MODULE__, :current)
  end
end
