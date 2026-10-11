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

  @impl GenServer
  def init(_) do
    Bus.subscribe("messages")
    {:ok, %{sources: %{}, units: %{}}}
  end

  @impl GenServer
  def handle_info(%Bus.Message{name: name, value: metric_value, source: source} = message, state) do
    state =
      case state.sources[source] do
        nil -> put_in(state, [:sources, source], %{})
        _ -> state
      end

    state = put_in(state, [:sources, source, name], metric_value)
    {:noreply, record_unit(state, source, name, message.unit)}
  end

  defp record_unit(state, _source, _name, nil), do: state

  defp record_unit(state, source, name, unit) do
    units = Map.get(state, :units, %{})
    Map.put(state, :units, Map.update(units, source, %{name => unit}, &Map.put(&1, name, unit)))
  end

  @impl GenServer
  def handle_call({:metrics, nil}, _from, state) do
    {:reply, {:ok, state.sources}, state}
  end

  def handle_call(:units, _from, state) do
    {:reply, {:ok, Map.get(state, :units, %{})}, state}
  end

  def handle_call({:metrics, source}, _from, state) do
    {:reply, {:ok, Map.get(state.sources, source, %{})}, state}
  end

  @doc "The last value of each metric `source` published."
  def metrics(source) do
    GenServer.call(__MODULE__, {:metrics, source})
  end

  @doc "The last value of every metric, by source."
  def metrics do
    GenServer.call(__MODULE__, {:metrics, nil})
  end

  @doc "The last unit of every metric whose publisher gave one, by source."
  def units do
    GenServer.call(__MODULE__, :units)
  end

  @doc """
  The metrics in `filter`, a map of source to a map whose keys are the
  metric names to keep.
  """
  def filtered_metrics(filter) do
    {:ok, metrics} = metrics()
    {:ok, filter_by_source(metrics, filter)}
  end

  @doc """
  The units of the metrics in `filter`, for those whose publisher gave
  one.
  """
  def filtered_units(filter) do
    {:ok, units} = units()
    {:ok, filter_by_source(units, filter)}
  end

  defp filter_by_source(by_source, filter) do
    by_source
    |> Enum.reduce(%{}, fn {source, source_metrics}, filtered ->
      case filter[source] do
        nil ->
          filtered

        _ ->
          source_metrics = source_metrics |> Map.take(Map.keys(filter[source]))
          filtered |> put_in([source], source_metrics)
      end
    end)
  end
end
