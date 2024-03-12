defmodule VmsCore.VwPolo.Abs do
  use GenServer

  require Logger

  @network_name :polo_drive

  @abs_status_frame_name "abs_status"

  @impl true
  def init(_) do
    :ok = Cantastic.Receiver.subscribe(self(), @network_name, @abs_status_frame_name)
    #:ok = Cantastic.ReceivedFrameWatcher.enable(@network_name, @abs_status_frame_name)
    {:ok, %{
      speed: 0
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame,  _frame, [%{value: speed}] = _signals}, state) do
    {:noreply, %{state | speed: speed}}
  end

  def handle_info({:handle_missing_frame,  frame_name}, state) do
    Logger.warning("Frame #{@network_name}.#{frame_name} not emitted anymore")
    {:noreply, state}
  end

  @impl true
  def handle_call(:speed, _from, state) do
    {:reply, state.speed, state}
  end

  def speed() do
    GenServer.call(__MODULE__, :speed)
  end
end
