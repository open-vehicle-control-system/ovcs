defmodule VmsCore.NissanLeaf.Em57.Charger do
  use GenServer

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end
end
