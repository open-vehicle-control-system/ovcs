defmodule CotBridge.PositionTracker do
  @moduledoc """
  Caches the latest `:vehicle_position` and `:speed` messages seen on
  `OvcsBus`.

  Position: the VMS broadcasts `%OvcsBus.Message{name: :vehicle_position}`
  with a map value — see `VmsCore.Components.OVCS.Gnss` for the
  canonical shape (`:latitude` / `:longitude` in decimal degrees plus
  optional `:altitude`, `:heading`, `:fix_type`, …). Whichever
  component produced it — CAN GNSS receiver, Ethernet fetcher — the
  freshest value wins; the tracker doesn't discriminate on `:source`.

  Speed: OVCS convention keeps the vehicle speed with its own
  component (`:speed` messages in km/h — the ABS driver on OVCS1), so
  the position message doesn't carry one. The tracker follows the
  `:speed` messages of the configured `:speed_source` module and
  merges the freshest value into the position it hands out — dropped
  again once older than `:position_max_age_ms`, so a stalled speed
  feed degrades the track rather than freezing it.

  `latest/0` returns the merged position together with its age so the
  publisher can stop emitting when the position feed dries up.
  """
  use GenServer

  alias OvcsBus, as: Bus

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc "Latest known position: `{:ok, position, age_ms}`, or `:no_position` before the first fix."
  def latest do
    GenServer.call(__MODULE__, :latest)
  end

  @impl true
  def init(config) do
    :ok = Bus.subscribe("messages")

    {:ok,
     %{
       speed_source: config.speed_source,
       max_age_ms: config.position_max_age_ms,
       position: nil,
       position_received_at: nil,
       speed: nil,
       speed_received_at: nil
     }}
  end

  @impl true
  def handle_info(%Bus.Message{name: :vehicle_position, value: position}, state)
      when is_map(position) do
    {:noreply, %{state | position: position, position_received_at: now()}}
  end

  def handle_info(
        %Bus.Message{name: :speed, value: speed, source: source},
        %{speed_source: source} = state
      ) do
    {:noreply, %{state | speed: speed, speed_received_at: now()}}
  end

  def handle_info(%Bus.Message{}, state), do: {:noreply, state}

  @impl true
  def handle_call(:latest, _from, %{position: nil} = state) do
    {:reply, :no_position, state}
  end

  def handle_call(:latest, _from, state) do
    age_ms = now() - state.position_received_at
    position = Map.put(state.position, :speed, fresh_speed(state))
    {:reply, {:ok, position, age_ms}, state}
  end

  defp fresh_speed(%{speed: nil}), do: nil

  defp fresh_speed(state) do
    if now() - state.speed_received_at <= state.max_age_ms, do: state.speed
  end

  defp now, do: System.monotonic_time(:millisecond)
end
