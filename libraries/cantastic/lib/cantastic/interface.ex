defmodule Cantastic.Interface do
  use GenServer
  alias Cantastic.{Signal, Util, CompiledSignalSpec, Frame}
  require Logger

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  def process_name(network_name) do
    "#{network_name |> String.capitalize()}CanBusInterface" |> String.to_atom
  end

  @impl true
  def init([network_name, interface, bitrate, manual_setup, signal_specs, frame_handler]) do
    :ok                   = Util.setup_can_interface(interface, bitrate, manual_setup)
    {:ok, socket}         = Util.bind_socket(interface)
    compiled_signal_specs = compile_signal_specs(signal_specs, network_name)
    receive_frame()
    {:ok,
      %{
        network_name: network_name,
        socket: socket,
        signal_specs: signal_specs, compiled_signal_specs: compiled_signal_specs,
        frame_handler: frame_handler
      }
    }
  end

  @impl true
  def handle_cast(:receive_frame, state) do
    {:ok, frame} = Util.receive_one_frame(state.socket)
    signals = (state.compiled_signal_specs[frame.id] || []) |> Enum.map(fn(compiled_signal_spec) ->
      {:ok, signal} =  Signal.from_frame_for_compiled_spec(frame, compiled_signal_spec)
      signal
    end)
    send_signals_to_frame_handler(state, frame, signals)
    receive_frame()
    {:noreply, state}
  end

  defp send_signals_to_frame_handler(_state, _frame, []), do: nil
  defp send_signals_to_frame_handler(state, frame, signals) do
    Logger.debug(Frame.to_string(frame))
    state.frame_handler.handle_frame(frame, signals)
  end

  defp receive_frame do
    GenServer.cast(self(), :receive_frame)
  end

  # {800: [{name: 'handbrakeEngaged', value: true, mapping: ....}, {name: 'handbrakeError': {value: true, ...}}]}
  defp compile_signal_specs(signal_specs, network_name) do
    signal_specs
    |> Enum.filter(fn({_key, %{"canNetwork" => network}}) -> network == network_name end)
    |> Map.new()
    |> Map.keys()
    |> Enum.reduce(%{}, fn(signal_name, compiled_signal_specs) ->
      signal_spec = signal_specs[signal_name]
      {:ok, compiled_signal_spec} = CompiledSignalSpec.from_signal_spec(signal_name, signal_spec)
      existing_compiled_signal_specs_for_frame = compiled_signal_specs[compiled_signal_spec.frame_id] || []
      compiled_signal_specs |> Map.put(compiled_signal_spec.frame_id, [compiled_signal_spec | existing_compiled_signal_specs_for_frame])
    end)
  end
end