defmodule Cantastic.Emitter do
  use GenServer

  def start_link(%{process_name: process_name} = args) do
    GenServer.start_link(__MODULE__, args, name: process_name)
  end

  @impl true
  def init(%{frequency: frequency, frame_sending_function: frame_sending_function, initial_data: initial_data, initialy_enabled: initialy_enabled}) do
    if initialy_enabled do
      enable(self())
    end
    {:ok,
      %{
        frame_sending_function: frame_sending_function,
        sending_timer: nil,
        data: initial_data,
        frequency: frequency
      }
    }
  end

  @impl true
  def handle_info(:send_frame, state) do
    {:ok, state} = state.frame_sending_function.(state)
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

  def send_frame(emitter) do
    Process.send_after(emitter, :send_frame, 0)
  end

  def enable(emitter) do
    GenServer.cast(emitter, :enable)
  end

  def disable(emitter) do
    GenServer.cast(emitter, :disable)
  end

  def get(emitter, fun, timeout \\ 5000) when is_function(fun, 1) do
    GenServer.call(emitter, {:get, fun}, timeout)
  end

  def update(emitter, fun, timeout \\ 5000) when is_function(fun, 1) do
    GenServer.call(emitter, {:update, fun}, timeout)
  end

  def batch_enable(emitters) do
    emitters |> Enum.each(
      fn (emitter) ->
        enable(emitter)
      end
    )
  end

  def batch_disable(emitters) do
    emitters |> Enum.each(
      fn (emitter) ->
        disable(emitter)
      end
    )
  end
end
