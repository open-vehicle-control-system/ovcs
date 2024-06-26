defmodule VmsCore.VwPolo.IgnitionLock do
  use GenServer
  alias Cantastic.{Frame, Signal}

  @network_name :polo_drive

  @key_status_frame_name "key_status"

  @impl true
  def init(_) do
    Cantastic.Receiver.subscribe(self(), @network_name, @key_status_frame_name)
    {:ok, %{
      key_status: "off"
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
  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{"key_state" => %Signal{value: key_status}} = signals
    {:noreply, %{state | key_status: key_status}}
  end

  @impl true
  def handle_call(:key_status, _from, state) do
    {:reply, {:ok, state.key_status}, state}
  end

  def key_status() do
    GenServer.call(__MODULE__, :key_status)
  end
end
