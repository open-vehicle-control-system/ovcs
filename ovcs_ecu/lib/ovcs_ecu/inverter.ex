defmodule OvcsEcu.Inverter do
  use GenServer

  @impl true
  def init(_) do
    :ok = OvcsEcu.NissanLeaf.Em57.Inverter.init_emitters()
    {:ok, %{}}
  end

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def on() do
    # Trigger 12v on pin IGN_SW
    OvcsEcu.NissanLeaf.Em57.Inverter.on()
  end

  def ready_to_drive?() do
    # Trigger 12v on pin IGN_SW
    OvcsEcu.NissanLeaf.Em57.Inverter.ready_to_drive?()
  end

  def throttle(torque) do
    # Trigger 12v on pin IGN_SW
    OvcsEcu.NissanLeaf.Em57.Inverter.throttle(torque)
  end
end
