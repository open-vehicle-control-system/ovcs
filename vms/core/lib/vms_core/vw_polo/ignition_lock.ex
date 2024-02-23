defmodule VmsCore.VwPolo.IgnitionLock do
  use GenServer
  alias Cantastic.Frame

  @network_name :drive

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

  @impl true
  def handle_info({:handle_frame,  %Frame{name: @key_status_frame_name}, [key_status_signal]}, state) do
    key_status = key_status_signal.value
    {:noreply, %{state | key_status: key_status}}
  end

  @impl true
  def handle_call(:key_status, _from, state) do
    {:reply, state.key_status, state}
  end

  def key_status() do
    GenServer.call(__MODULE__, :key_status)
  end

  def last_ignition_requested_at() do
    0
  end
end
