defmodule VmsCore.BatteryManagementSystem do
  use GenServer
  alias VmsCore.OvcsControllers.ContactorsController

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def high_voltage_on() do
    ContactorsController.on()
  end

  def high_voltage_off() do
    ContactorsController.off()
  end

  def ready_to_drive?() do
    false
  end
end
