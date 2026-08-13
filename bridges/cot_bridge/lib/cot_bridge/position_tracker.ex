defmodule CotBridge.PositionTracker do
  @moduledoc """
  Caches the latest `:vehicle_position` message seen on `OvcsBus`.

  The VMS broadcasts `%OvcsBus.Message{name: :vehicle_position}` with
  a map value — see `VmsCore.Components.OVCS.Gnss` for the canonical
  shape (`:latitude` / `:longitude` in decimal degrees plus optional
  `:altitude`, `:speed`, `:heading`, `:fix_type`, …). Whichever
  component produced it — CAN GNSS receiver, Ethernet fetcher — the
  freshest value wins; the tracker doesn't discriminate on `:source`.

  `latest/0` returns the cached position together with its age so the
  publisher can stop emitting when the feed dries up.
  """
  use GenServer

  alias OvcsBus, as: Bus

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc "Latest known position: `{:ok, position, age_ms}`, or `:no_position` before the first fix."
  def latest do
    GenServer.call(__MODULE__, :latest)
  end

  @impl true
  def init(_) do
    :ok = Bus.subscribe("messages")
    {:ok, %{position: nil, received_at: nil}}
  end

  @impl true
  def handle_info(%Bus.Message{name: :vehicle_position, value: position}, state)
      when is_map(position) do
    {:noreply, %{state | position: position, received_at: System.monotonic_time(:millisecond)}}
  end

  def handle_info(%Bus.Message{}, state), do: {:noreply, state}

  @impl true
  def handle_call(:latest, _from, %{position: nil} = state) do
    {:reply, :no_position, state}
  end

  def handle_call(:latest, _from, state) do
    age_ms = System.monotonic_time(:millisecond) - state.received_at
    {:reply, {:ok, state.position, age_ms}, state}
  end
end
