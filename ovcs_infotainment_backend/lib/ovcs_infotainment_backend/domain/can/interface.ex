defmodule OvcsInfotainmentBackend.Can.Interface do
  use GenServer
  alias OvcsInfotainmentBackend.Can.{Signal, Util, CompiledSignalSpec}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args)
  end

  @impl true
  def init([network_name, interface, bitrate, signal_specs]) do
    Util.setup_can_interface(interface, bitrate)
    {:ok, socket} = Util.bind_socket(interface)
    compiled_signal_specs = compile_signal_specs(signal_specs)
    receive_frame()
    {:ok,
      %{
        network_name: network_name,
        socket: socket,
        signal_specs: signal_specs, compiled_signal_specs: compiled_signal_specs
      }
    }
  end

  @impl true
  def handle_info(:receive_frame, state) do
    {:ok, frame} = Util.receive_one_frame(state.socket)
    IO.inspect frame
    (state.compiled_signal_specs[frame.id] || []) |> Enum.each(fn(compiled_signal_spec) ->
      {:ok, signal} =  Signal.from_frame_for_compiled_spec(frame, compiled_signal_spec)
      IO.inspect signal
      IO.inspect OvcsInfotainmentBackendWeb.Endpoint.broadcast!("debug-metrics", "update_handbrake", signal)
    end)
    receive_frame()
    {:noreply, state}
  end

  defp receive_frame do
    send(self(), :receive_frame)
  end

  # {800: [{name: 'handbrakeEngaged', value: true, mapping: ....}, {name: 'handbrakeError': {value: true, ...}}]}
  defp compile_signal_specs(signal_specs) do
    signal_specs |> Map.keys() |> Enum.reduce(%{}, fn(signal_name, compiled_signal_specs) ->
      signal_spec = signal_specs[signal_name]
      {:ok, compiled_signal_spec} = CompiledSignalSpec.from_signal_spec(signal_name, signal_spec)
      existing_compiled_signal_specs_for_frame = compiled_signal_specs[compiled_signal_spec.frame_id] || []
      compiled_signal_specs |> Map.put(compiled_signal_spec.frame_id, [compiled_signal_spec | existing_compiled_signal_specs_for_frame])
    end)
  end
end
