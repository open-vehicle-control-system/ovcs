defmodule OvcsInfotainmentBackend.VehicleStateManager do
  use GenServer

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  def handle_frame(frame, signals) do
    GenServer.cast(__MODULE__, {:handle_frame, frame, signals})
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
  def handle_cast({:handle_frame, frame, signals}, state) do
    IO.inspect frame
    IO.inspect signals
    new_signals_state = signals |> Enum.reduce(state.signals, fn(signal, signals_state) ->
      current_signal = signals_state[signal.name]
      last_updated_at = signals_state.updated_at
      new_state = case is_nil(current_signal) || current_signal.value != signal.value do
        true ->
          signals_state
          |> Map.put(signal.name, signal)
          |> Map.put(:updated_at, DateTime.to_unix(DateTime.utc_now()))
        false ->
          signals_state
      end
      if last_updated_at != new_state.updated_at do
        OvcsInfotainmentBackendWeb.Endpoint.broadcast!("debug-metrics", "update_handbrake", signals |> List.first())
      end
      new_state
    end)
    {:noreply, %{state | signals: new_signals_state}}
  end
end
