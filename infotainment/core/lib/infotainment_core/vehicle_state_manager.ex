defmodule InfotainmentCore.VehicleStateManager do
  use GenServer
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_args) do
    Cantastic.Receiver.subscribe(self())
    {:ok,
    %{
        clients: [],
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
  def handle_call(:get_can_config, _from, state) do
    {:reply, state.can_config, state}
  end

  @impl true
  def handle_cast({:subscribe, client}, state) do
    {:noreply, %{state | clients: [client | state.clients]}}
  end

  @impl true
  def handle_info({:handle_frame,  frame}, state) do
    last_updated_at = state.signals.updated_at
    new_signals_state = frame.signals |> Enum.reduce(state.signals, fn({signal_name, signal}, signals_state) ->
      current_signal = signals_state[signal_name]
      case is_nil(current_signal) || current_signal.value != signal.value do
        true ->
          signals_state
          |> Map.put(signal_name, signal)
          |> Map.put(:updated_at, now())
          false ->
            signals_state
          end
        end)
        if last_updated_at != new_signals_state.updated_at do
          state.clients |> Enum.each(fn (client) ->
            GenServer.cast(client, {:signals_updated, signals_only(new_signals_state)})
          end)
        end
        {:noreply, %{state | signals: new_signals_state}}
      end

      defp now() do
        System.os_time(:microsecond)
      end

      defp signals_only(signals) do
        signals
        |> Map.drop([:updated_at])
      end

      def signals() do
        GenServer.call(__MODULE__, :get_signals)
      end

      def subscribe(client) do
        GenServer.cast(__MODULE__, {:subscribe, client})
      end
    end
