defmodule VmsCore.Inverter do
  use GenServer
  alias VmsCore.Controllers.FrontController
  alias VmsCore.NissanLeaf.Em57
  alias VmsCore.VwPolo

  defdelegate throttle(percentage_torque, selected_gear, allowed_discharge_power), to: Em57.Inverter
  defdelegate inverter_state(), to: Em57.Inverter
  defdelegate rotation_per_minute(), to: Em57.Inverter

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def handle_cast(:on, state) do
    with  :ok <- FrontController.switch_on_inverter(),
          :ok <- Em57.Inverter.on(),
          :ok <- VwPolo.Engine.on()
    do
      {:noreply, state}
    else
      :unexpected -> :unexpected
    end
  end

  @impl true
  def handle_cast(:off, state) do
    with :ok <- VwPolo.Engine.off(),
         :ok <- FrontController.switch_off_inverter(),
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
    {:ok, vms_controller_ready} = FrontController.ready_to_drive?()
    {:ok, inverter_ready}       = Em57.Inverter.ready_to_drive?()
    {:ok, vms_controller_ready && inverter_ready}
  end
end
