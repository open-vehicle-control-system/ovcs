defmodule VmsCore.BatteryManagementSystem do
  use GenServer
  alias VmsCore.Controllers.ContactorsController

  defdelegate ready_to_drive?, to: ContactorsController

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_cast(:high_voltage_on, state) do
    with :ok <- ContactorsController.on()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end

  @impl true
  def handle_cast(:high_voltage_off, state) do
    with :ok <- ContactorsController.off()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end


  def high_voltage_on() do
    GenServer.cast(__MODULE__, :high_voltage_on)
  end

  def high_voltage_off() do
    GenServer.cast(__MODULE__, :high_voltage_off)
  end
end
