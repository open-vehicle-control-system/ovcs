defmodule Cantastic.Receiver do
  use GenServer
  alias Cantastic.{Signal, CompiledFrameSpec, Frame, Interface}
  require Logger

  def start_link([process_name | args_tail] = _args) do
    GenServer.start_link(__MODULE__, args_tail, name: process_name)
  end

  @impl true
  def init([network_name, socket, compiled_received_frame_specs]) do
    receive_frame()
    {:ok,
      %{
        network_name: network_name,
        socket: socket,
        compiled_received_frame_specs: compiled_received_frame_specs
      }
    }
  end

  @impl true
  def handle_info(:receive_frame, state) do
    {:ok, frame} = receive_one_frame(state.network_name, state.socket)
    compiled_frame_spec = (state.compiled_received_frame_specs[frame.id] || %CompiledFrameSpec{})
    signals = (compiled_frame_spec.compiled_signal_specs || []) |> Enum.map(fn(compiled_signal_spec) ->
      {:ok, signal} =  Signal.from_frame_for_compiled_spec(frame, compiled_signal_spec)
      signal
    end)
    frame = %{frame | name: compiled_frame_spec.name}
    send_signals_to_frame_handler(compiled_frame_spec.frame_handlers, frame, signals)
    receive_frame()
    {:noreply, state}
  end

  defp receive_one_frame(network_name, socket) do
    {:ok, raw_frame} = :socket.recv(socket)
    <<
      id::little-integer-size(16),
      _unused1::binary-size(2),
      data_length::little-integer-size(8),
      _unused2::binary-size(3),
      raw_data::binary-size(data_length),
      _unused3::binary
    >> = raw_frame
    frame = %Frame{
      id: id,
      network_name: network_name,
      data_length: data_length,
      raw_data: raw_data
    }
    {:ok, frame}
  end

  @impl true
  def handle_call({:subscribe, frame_handler, frame_names}, _from, state) do
    state = frame_names |> Enum.reduce(state, fn(frame_name, new_state) ->
      {:ok, compiled_frame_spec} = find_compiled_frame_spec_by_name(state.compiled_received_frame_specs, frame_name)
      frame_handlers = [frame_handler | compiled_frame_spec.frame_handlers]
      put_in(new_state, [:compiled_received_frame_specs, compiled_frame_spec.id, :frame_handlers], frame_handlers)
    end)
    {:reply, :ok, state}
  end

  def find_compiled_frame_spec_by_name(compiled_received_frame_specs, frame_name) do
    {_frame_id, compiled_frame_spec} = compiled_received_frame_specs |> Enum.find(fn ({_frame_id, compiled_frame_spec}) ->
      compiled_frame_spec.name == frame_name
    end)
    {:ok, compiled_frame_spec}
  end

  defp send_signals_to_frame_handler(_frame_handlers, _frame, []), do: nil
  defp send_signals_to_frame_handler(frame_handlers, frame, signals) do
    Logger.debug(Frame.to_string(frame))
    frame_handlers |> Enum.each(fn (frame_handler) ->
      Process.send(frame_handler, {:handle_frame, frame, signals}, [])
    end)
  end

  defp receive_frame do
    Process.send_after(self(), :receive_frame, 0)
  end

  def subscribe(frame_handler, network_name, frame_names) do
    receiver =  Interface.receiver_process_name(network_name)
    GenServer.call(receiver, {:subscribe, frame_handler, frame_names})
  end
end
