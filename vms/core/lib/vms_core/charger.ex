defmodule VmsCore.Charger do
  use GenServer

  alias VmsCore.NissanLeaf.Em57

  defdelegate ac_voltage(), to: Em57.Charger
  defdelegate maximum_power_for_charger(power), to: Em57.Charger

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end
end
