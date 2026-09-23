defmodule VmsCore.Metrics do
  @moduledoc """
  The last value of every message on the VMS bus, per source and name,
  and the last unit its publisher gave it.
  """
  use GenServer
  alias OvcsBus, as: Bus

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Bus.subscribe("messages")
    {:ok, %{sources: %{}, units: %{}}}
  end

  @impl true
  def handle_info(%Bus.Message{name: name, value: value, source: source} = message, state) do
    state =
      case state.sources[source] do
        nil -> put_in(state, [:sources, source], %{})
        _ -> state
      end

    state = put_in(state, [:sources, source, name], value)
    {:noreply, record_unit(state, source, name, message.unit)}
  end

  defp record_unit(state, _source, _name, nil), do: state

  defp record_unit(state, source, name, unit) do
    units = Map.get(state, :units, %{})
    Map.put(state, :units, Map.update(units, source, %{name => unit}, &Map.put(&1, name, unit)))
  end

  @impl true
  def handle_call({:metrics, nil}, _from, state) do
    {:reply, {:ok, state.sources}, state}
  end

  def handle_call(:units, _from, state) do
    {:reply, {:ok, Map.get(state, :units, %{})}, state}
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

  def units do
    GenServer.call(__MODULE__, :units)
  end

  def filtered_metrics(filter) do
    {:ok, metrics} = metrics()
    {:ok, filter(metrics, filter)}
  end

  @doc """
  The units of the metrics in `filter`, for those whose publisher gave
  one.
  """
  def filtered_units(filter) do
    {:ok, units} = units()
    {:ok, filter(units, filter)}
  end

  defp filter(by_source, filter) do
    by_source
    |> Enum.reduce(%{}, fn {module, module_metrics}, result ->
      case filter[module] do
        nil ->
          result

        _ ->
          module_metrics = module_metrics |> Map.take(Map.keys(filter[module]))
          result |> put_in([module], module_metrics)
      end
    end)
  end
end
