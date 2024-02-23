defmodule VmsCore.Inverter do
  use GenServer

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def on() do
    VmsCore.Controllers.VmsController.switch_on_inverter_relay()
    VmsCore.NissanLeaf.Em57.Inverter.on()
  end

  def off() do
    VmsCore.Controllers.VmsController.switch_off_inverter_relay()
    VmsCore.NissanLeaf.Em57.Inverter.off()
  end

  def ready_to_drive?() do
    # Trigger 12v on pin IGN_SW
    VmsCore.NissanLeaf.Em57.Inverter.ready_to_drive?()
  end

  def throttle(torque) do
    # Trigger 12v on pin IGN_SW
    VmsCore.NissanLeaf.Em57.Inverter.throttle(torque)
  end
end
