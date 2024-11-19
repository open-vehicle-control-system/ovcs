defmodule VmsCore.Metrics do
  @moduledoc """
    Aggregate all metrics emmited on the VMS bus
  """
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
  def handle_call({:metrics, nil}, _from, state) do
    {:reply, {:ok, state.sources}, state}
  end
  def handle_call({:metrics, source}, _from, state) do
    {:reply, {:ok, Map.get(state.sources, source, %{})}, state}
  end

  def metrics(source) do
    GenServer.call(__MODULE__, {:metrics, source})
  end
  def metrics do
    GenServer.call(__MODULE__, {:metrics, nil})
  end

  def filtered_metrics(filter) do
    {:ok, metrics} =  metrics()
    filtered = metrics |> Enum.reduce(%{}, fn({module, module_metrics}, result) ->
      case filter[module] do
        nil -> result
        _ ->
          module_metrics = module_metrics |> Map.take(Map.keys(filter[module]))
          result |> put_in([module], module_metrics)
      end
    end)
    {:ok, filtered}
  end
end
