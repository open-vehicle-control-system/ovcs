defmodule VmsCore.Vehicles.OVCS1 do
  use GenServer
  alias VmsCore.Bus

  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{contact_source: contact_source}) do
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      contact: :off,
      ready_to_drive: false,
      loop_timer: timer,
      ignition_started: false,
      contact_source: contact_source
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
    {:noreply, %{state | contact: contact}}
  end

  # defp start_ignition(state) do
  #   with :ok <- BreakingSystem.on(),
  #        :ok <- Inverter.on(),
  #        :ok <- BatteryManagementSystem.high_voltage_on()
  #   do
  #     %{state | ignition_started: true}
  #   else
  #     :unexpected -> :unexpected
  #   end
  # end

  # defp shutdown(state) do
  #   with :ok <- VmsCore.VwPolo.PowerSteeringPump.off(),
  #        :ok <- BreakingSystem.off(),
  #        :ok <- Inverter.off(),
  #        :ok <- BatteryManagementSystem.high_voltage_off()
  #   do
  #     %{state | ignition_started: false}
  #   else
  #     :unexpected -> :unexpected
  #   end
  # end
end
