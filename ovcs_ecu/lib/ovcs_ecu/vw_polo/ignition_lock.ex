defmodule OvcsEcu.VwPolo.IgnitionLock do
  use GenServer

  @network_name "drive"

  @impl true
  def init(_) do
    Cantastic.Receiver.subscribe(self(), @network_name, ["keyStatus"])
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_info({:handle_frame, _frame, signals}, state) do
    IO.inspect "-----"
    IO.inspect signals
    {:noreply, state}
  end

  def last_ignition_requested_at() do
    0
  end
end
