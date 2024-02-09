defmodule Cantastic.Receiver do
  use GenServer
  alias Cantastic.{Signal, CompiledFrameSpec, Frame}
  require Logger

  def start_link([process_name | args_tail] = _args) do
    GenServer.start_link(__MODULE__, args_tail, name: process_name)
  end

  @impl true
  def init([network_name, socket, compiled_received_frame_specs, frame_handler]) do
    receive_frame()
    {:ok,
      %{
        network_name: network_name,
        socket: socket,
        compiled_received_frame_specs: compiled_received_frame_specs,
        frame_handler: frame_handler
      }
    }
  end

  @impl true
  def handle_cast(:receive_frame, state) do
    {:ok, frame} = receive_one_frame(state.network_name, state.socket)
    signals = ((state.compiled_received_frame_specs[frame.id] || %CompiledFrameSpec{}).compiled_signal_specs || []) |> Enum.map(fn(compiled_signal_spec) ->
      {:ok, signal} =  Signal.from_frame_for_compiled_spec(frame, compiled_signal_spec)
      signal
    end)
    send_signals_to_frame_handler(state, frame, signals)
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

  defp send_signals_to_frame_handler(_state, _frame, []), do: nil
  defp send_signals_to_frame_handler(state, frame, signals) do
    Logger.debug(Frame.to_string(frame))
    state.frame_handler.handle_frame(frame, signals)
  end

  defp receive_frame do
    GenServer.cast(self(), :receive_frame)
  end
end
