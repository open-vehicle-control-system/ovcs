defmodule VmsCore.IgnitionLock do
  use GenServer

  defdelegate key_status(), to: VmsCore.VwPolo.IgnitionLock

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end
end
