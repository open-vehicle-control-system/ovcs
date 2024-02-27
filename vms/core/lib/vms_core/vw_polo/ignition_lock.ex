defmodule VmsCore.VwPolo.IgnitionLock do
  use GenServer

  @network_name :polo_drive

  @key_status_frame_name "key_status"

  @impl true
  def init(_) do
    Cantastic.Receiver.subscribe(self(), @network_name, [@key_status_frame_name])
    {:ok, %{
      key_status: nil
    }}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  # off
  # key_engaged
  # contact_on
  # start_engine
  @impl true
  def handle_info({:handle_frame,  _frame, [%{value: key_status}] = _signals}, state) do
    {:noreply, %{state | key_status: key_status}}
  end

  @impl true
  def handle_call(:key_status, _from, state) do
    {:reply, state.key_status, state}
  end

  def key_status() do
    GenServer.call(__MODULE__, :key_status)
  end
end
