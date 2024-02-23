defmodule Cantastic.Receiver do
  use GenServer
  alias Cantastic.{Signal, FrameSpecification, Frame, Interface, ConfigurationStore}
  require Logger

  def start_link([process_name | args_tail] = _args) do
    GenServer.start_link(__MODULE__, args_tail, name: process_name)
  end

  @impl true
  def init([network_name, socket, frame_specifications]) do
    receive_frame()
    {:ok,
      %{
        network_name: network_name,
        socket: socket,
        frame_specifications: frame_specifications
      }
    }
  end

  @impl true
  def handle_info(:receive_frame, state) do
    {:ok, frame} = receive_one_frame(state.network_name, state.socket)
    frame_specification = (state.frame_specifications[frame.id] || %FrameSpecification{})
    signals = (frame_specification.signal_specifications || []) |> Enum.map(fn(signal_specification) ->
      {:ok, signal} =  Signal.from_frame_for_specification(frame, signal_specification)
      signal
    end)
    frame = %{frame | name: frame_specification.name}
    send_signals_to_frame_handler(frame_specification.frame_handlers, frame, signals)
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
  def handle_cast({:subscribe, frame_handler, frame_names}, state) do
    frame_names = case frame_names do
      "*"   -> frame_names(state)
      [_|_] -> frame_names
    end
    state = frame_names |> Enum.reduce(state, fn(frame_name, new_state) ->
      {:ok, frame_specification} = find_frame_specification_by_name(state.frame_specifications, frame_name)
      frame_handlers = [frame_handler | frame_specification.frame_handlers]
      put_in(new_state, [:frame_specifications, frame_specification.id, :frame_handlers], frame_handlers)
    end)
    {:noreply, state}
  end

  def find_frame_specification_by_name(frame_specifications, frame_name) do
    {_frame_id, frame_specification} = frame_specifications |> Enum.find(fn ({_frame_id, frame_specification}) ->
      frame_specification.name == frame_name
    end)
    {:ok, frame_specification}
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

  def subscribe(frame_handler) do
    ConfigurationStore.networks()|> Enum.each(fn (network) ->
      receiver =  Interface.receiver_process_name(network.network_name)
      GenServer.cast(receiver, {:subscribe, frame_handler, "*"})
    end)
  end
  def subscribe(frame_handler, network_name, frame_names) do
    receiver =  Interface.receiver_process_name(network_name)
    GenServer.cast(receiver, {:subscribe, frame_handler, frame_names})
  end

  def frame_names(state) do
    state.frame_specifications |> Enum.map(fn({_frame_id, frame_specification}) ->
      frame_specification.name
    end)
  end
end
