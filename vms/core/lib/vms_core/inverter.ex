defmodule VmsCore.Inverter do
  use GenServer
  alias VmsCore.Controllers.VmsController
  alias VmsCore.NissanLeaf.Em57

  defdelegate throttle(percentage_torque), to: Em57.Inverter

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_cast(:on, state) do
    with :ok <- VmsController.switch_on_inverter_relay(),
         :ok <- Em57.Inverter.on()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end

  @impl true
  def handle_cast(:off, state) do
    with :ok <- VmsController.switch_off_inverter_relay(),
         :ok <- Em57.Inverter.off()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end

  def on() do
    GenServer.cast(__MODULE__, :on)
  end

  def off() do
    GenServer.cast(__MODULE__, :off)
  end

  def ready_to_drive?() do
    VmsController.ready_to_drive?() && Em57.Inverter.ready_to_drive?()
  end
end
