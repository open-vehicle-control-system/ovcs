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
  def handle_call(:get_speed, _from, state) do
    speed_signal = state.signals["speed"]
    case speed_signal do
      nil ->
        {:reply, %{speed: 0, unit: "km/h"}, state}
      _ ->
        {:reply, %{speed: speed_signal.attributes.value, unit: speed_signal.attributes.unit}, state}
    end
  end

  @impl true
  def handle_call(:get_car_overview, _from, state) do
    metrics = %{
      rear_left_door_open: convert_to_map(state.signals["rear_left_door_open"], false, nil),
      front_left_door_open: convert_to_map(state.signals["front_left_door_open"], false, nil),
      rear_right_door_open: convert_to_map(state.signals["rear_right_door_open"], false, nil),
      front_right_door_open: convert_to_map(state.signals["front_right_door_open"], false, nil),
      beam_active: convert_to_map(state.signals["beam_active"], false, nil),
      trunk_door_open: convert_to_map(state.signals["trunk_door_open"], false, nil),
      handbrake_engaged: convert_to_map(state.signals["handbrake_engaged"], false, nil),
      ready_to_drive: convert_to_map(state.signals["ready_to_drive"], false, nil),
      vms_status: convert_to_map(state.signals["vms_status"], "off", nil)
    }
    {:reply, {:ok, metrics}, state}
  end

  defp convert_to_map(nil, default_value, default_unit) do
    %{value: default_value, unit: default_unit}
  end
  defp convert_to_map(signal, _, _) do
    %{value: signal.value, unit: signal.unit}
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

      def get_speed() do
        GenServer.call(__MODULE__, :get_speed)
      end

      def get_car_overview() do
        GenServer.call(__MODULE__, :get_car_overview)
      end

      def signals() do
        GenServer.call(__MODULE__, :get_signals)
      end

      def subscribe(client) do
        GenServer.cast(__MODULE__, {:subscribe, client})
      end
    end
