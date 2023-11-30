defmodule OvcsInfotainmentBackend.VehicleStateManager do
  use GenServer
  require Logger
  alias OvcsInfotainmentBackend.Can.Signal

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def handle_frame(frame, signals) do
    GenServer.cast(__MODULE__, {:handle_frame, frame, signals})
  end

  def signals() do
    GenServer.call(__MODULE__, :get_signals)
  end

  @impl true
  def init([vehicle_config]) do
    {:ok,
      %{
        model: vehicle_config["model"],
        brand: vehicle_config["brand"],
        signals: %{
          updated_at: nil
        }
      }
    }
  end

  @impl true
  def handle_call(:get_signals, _from, state) do

    {:reply, signals_only(state.signals), state}
  end

  @impl true
  def handle_cast({:handle_frame, _frame, signals}, state) do
    last_updated_at = state.signals.updated_at
    new_signals_state = signals |> Enum.reduce(state.signals, fn(signal, signals_state) ->
      Logger.debug(Signal.to_string(signal))
      current_signal = signals_state[signal.name]
      case is_nil(current_signal) || current_signal.value != signal.value do
        true ->
          signals_state
          |> Map.put(signal.name, signal)
          |> Map.put(:updated_at, now())
        false ->
          signals_state
      end
    end)
    if last_updated_at != new_signals_state.updated_at do
      OvcsInfotainmentBackendWeb.Endpoint.broadcast!("debug-metrics", "update", signals_only(new_signals_state))
    end
    {:noreply, %{state | signals: new_signals_state}}
  end

  defp now() do
    DateTime.utc_now()
    |> DateTime.to_unix()
  end

  defp signals_only(signals) do
    signals
    |> Map.drop([:updated_at])
  end
end
