defmodule Cantastic.Emitter do
  use GenServer
  alias Cantastic.{Interface, Frame}

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name:  _, frame_specification: frame_specification, socket: socket, network_name: network_name}) do
    {:ok,
      %{
        socket: socket,
        network_name: network_name,
        parameters_builder_function: nil,
        sending_timer: nil,
        data: %{},
        frequency: frame_specification.frequency,
        frame_specification: frame_specification
      }
    }
  end

  @impl true
  def handle_info(:send_frame, state) do
    {:ok, parameters, state} = state.parameters_builder_function.(state)
    {:ok, raw_frame}         = Frame.build_raw(state.frame_specification, parameters)
    :socket.send(state.socket, raw_frame)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:enable, state) do
    case state.sending_timer do
      nil ->
        {:ok, timer} = :timer.send_interval(state.frequency, :send_frame)
        {:noreply, %{state | sending_timer: timer}}
      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast(:disable, state) do
    case state.sending_timer do
      nil ->
        {:noreply, state}
      sending_timer ->
        {:ok, _} = :timer.cancel(sending_timer)
        {:noreply, %{state | sending_timer: nil}}
    end
  end

  @impl true
  def handle_call({:get, fun}, _from, state) do
    {:reply, fun.(state), state}
  end

  @impl true
  def handle_call({:update, fun}, _from, state) do
    state = fun.(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:configure, initialization_args}, _from, state) do
    state = state
    |> Map.put(:parameters_builder_function, initialization_args.parameters_builder_function)
    |> Map.put(:data, initialization_args.initial_data)
    {:reply, :ok, state}
  end

  def send_frame(emitter) do
    Process.send_after(emitter, :send_frame, 0)
  end

  def get(emitter, fun, timeout \\ 5000) when is_function(fun, 1) do
    GenServer.call(emitter, {:get, fun}, timeout)
  end

  def update(network_name, frame_name, fun, timeout \\ 5000) when is_function(fun, 1) do
    emitter =  Interface.emitter_process_name(network_name, frame_name)
    GenServer.call(emitter, {:update, fun}, timeout)
  end

  def configure(network_name, frame_name, initialization_args) do
    emitter =  Interface.emitter_process_name(network_name, frame_name)
    GenServer.call(emitter, {:configure, initialization_args})
  end

  def enable(network_name, frame_names) when is_list(frame_names) do
    frame_names |> Enum.each(
      fn (frame_name) ->
        enable(network_name, frame_name)
      end
    )
  end
  def enable(network_name, frame_name) do
    emitter = Interface.emitter_process_name(network_name, frame_name)
    GenServer.cast(emitter, :enable)
  end

  def disable(network_name, frame_names) when is_list(frame_names) do
    frame_names |> Enum.each(
      fn (frame_name) ->
        disable(network_name, frame_name)
      end
    )
  end
  def disable(network_name, frame_name) do
    emitter = Interface.emitter_process_name(network_name, frame_name)
    GenServer.cast(emitter, :disable)
  end
end
