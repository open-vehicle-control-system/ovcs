defmodule Cantastic.ReceivedFrameWatcher do
  use GenServer
  alias Cantastic.{Interface}

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{process_name:  _, frame_specification: frame_specification, network_name: network_name}) do
    :ok = Cantastic.Receiver.subscribe(self(), network_name, [frame_specification.name])
    {:ok,
      %{
        watching_timer: nil,
        network_name: network_name,
        frame_received_at: DateTime.utc_now(),
        frame_name: frame_specification.name,
        frame_handlers: frame_specification.frame_handlers,
        frame_frequency: frame_specification.frequency,
        frame_allowed_frequency_leeway: frame_specification.allowed_frequency_leeway,
        allowed_missing_frames: frame_specification.allowed_missing_frames,
        missed_frame_count: 0
      }
    }
  end

  @impl true
  def handle_info(:validate_frequency, state) do
    now          = DateTime.utc_now()
    diff         = DateTime.diff(now, state.frame_received_at, :millisecond)
    allowed_diff = state.frame_frequency + state.frame_allowed_frequency_leeway
    case {diff > allowed_diff, state.missed_frame_count} do
      {true, count} when count > state.allowed_missing_frames ->
        send_to_frame_handlers(state.frame_handlers, state.network_name, state.frame_name)
        {:noreply, state}
      {true, count} ->
        {:noreply, %{state | missed_frame_count: count + 1}}
      {false, _count} ->
        {:noreply, %{state | missed_frame_count: 0}}
    end
  end

  @impl true
  def handle_info({:handle_frame,  _frame}, state) do
    now = DateTime.utc_now()
    {:noreply, %{state | frame_received_at: now}}
  end

  defp send_to_frame_handlers(frame_handlers, network_name, frame_name) do
    frame_handlers |> Enum.each(fn (frame_handler) ->
      Process.send(frame_handler, {:handle_missing_frame, network_name, frame_name}, [])
    end)
  end

  @impl true
  def handle_call({:subscribe, frame_handler}, _from, state) do
    {:reply, :ok, %{state | frame_handlers: [frame_handler | state.frame_handlers]}}
  end

  @impl true
  def handle_call(:enable, _from, state) do
    case {state.frame_frequency, state.watching_timer}  do
      {nil, _} ->
        error = {:error, "No frequency was defined for frame #{state.frame_name}"}
        {:reply, error, state}
      {frequency, nil} ->
        {:ok, timer} = :timer.send_interval(frequency, :validate_frequency)
        {:reply, :ok, %{state | watching_timer: timer}}
      _ -> {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:disable, _from, state) do
    case state.watching_timer do
      nil ->
        {:reply, :ok, state}
      watching_timer ->
        {:ok, _} = :timer.cancel(watching_timer)
        {:reply, :ok, %{state | watching_timer: nil}}
    end
  end

  def subscribe(network_name, frame_names, frame_handler) when is_list(frame_names) do
    frame_names |> Enum.each(
      fn (frame_name) ->
        subscribe(network_name, frame_name, frame_handler)
      end
    )
  end
  def subscribe(network_name, frame_name, frame_handler) do
    watcher = Interface.received_frame_watcher_process_name(network_name, frame_name)
    GenServer.call(watcher, {:subscribe, frame_handler})
  end

  def enable(network_name, frame_names) when is_list(frame_names) do
    frame_names |> Enum.each(
      fn (frame_name) ->
        enable(network_name, frame_name)
      end
    )
  end
  def enable(network_name, frame_name) do
    watcher = Interface.received_frame_watcher_process_name(network_name, frame_name)
    GenServer.call(watcher, :enable)
  end

  def disable(network_name, frame_names) when is_list(frame_names) do
    frame_names |> Enum.each(
      fn (frame_name) ->
        disable(network_name, frame_name)
      end
    )
  end
  def disable(network_name, frame_name) do
    watcher = Interface.received_frame_watcher_process_name(network_name, frame_name)
    GenServer.call(watcher, :disable)
  end
end
