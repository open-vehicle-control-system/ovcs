defmodule OvcsEcu.IgnitionLock do
  use GenServer

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def last_ignition_requested_at() do
    OvcsEcu.VwPolo.IgnitionLock.last_ignition_requested_at()
  end
end
