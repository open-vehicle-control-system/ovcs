defmodule OvcsBusGateway.Cache do
  @moduledoc """
  Latest envelope of every signal seen on the bus.

  The process owns a named ETS table keyed by `OvcsBusGateway.Envelope.key/1`, which also
  holds the gateway's monotonic time each envelope was stored at. Only the collector writes,
  through `put_all/1` and `mark_stale/1`; any process reads the table directly.
  """

  use GenServer

  alias OvcsBusGateway.Envelope

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Stores `envelopes`, replacing the previous envelope of each signal. Later envelopes win.
  """
  @spec put_all([Envelope.t()]) :: :ok
  def put_all(envelopes), do: GenServer.call(__MODULE__, {:put_all, envelopes})

  @doc """
  Sets `stale: true` on every envelope with `stale: false` stored before `received_before`,
  a `System.monotonic_time(:millisecond)`, and returns the updated envelopes.
  """
  @spec mark_stale(integer()) :: [Envelope.t()]
  def mark_stale(received_before),
    do: GenServer.call(__MODULE__, {:mark_stale, received_before})

  @doc """
  The envelopes matching `filter`, sorted by `{node, source, name}`.
  """
  @spec select(OvcsBusGateway.filter()) :: [Envelope.t()]
  def select(filter) do
    key = {
      Map.get(filter, :node, :_),
      Map.get(filter, :source, :_),
      Map.get(filter, :name, :_)
    }

    @table
    |> :ets.match_object({key, :_, :_})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  @spec fetch({String.t(), String.t(), String.t()}) :: {:ok, Envelope.t()} | :error
  def fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, envelope, _received_at}] -> {:ok, envelope}
      [] -> :error
    end
  end

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, nil}
  end

  @impl GenServer
  def handle_call({:put_all, envelopes}, _from, state) do
    received_at = System.monotonic_time(:millisecond)
    :ets.insert(@table, Enum.map(envelopes, &{Envelope.key(&1), &1, received_at}))
    {:reply, :ok, state}
  end

  def handle_call({:mark_stale, received_before}, _from, state) do
    fresh = {:_, %{__struct__: Envelope, stale: false}, :"$1"}
    expired = :ets.select(@table, [{fresh, [{:<, :"$1", received_before}], [:"$_"]}])

    stale =
      for {key, envelope, received_at} <- expired do
        envelope = %{envelope | stale: true}
        :ets.insert(@table, {key, envelope, received_at})
        envelope
      end

    {:reply, stale, state}
  end
end
