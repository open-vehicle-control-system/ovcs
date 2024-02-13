defmodule OvcsEcu.OvcsControllers.CarControlsController do
  use GenServer

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def throttle() do
    0
  end
end
