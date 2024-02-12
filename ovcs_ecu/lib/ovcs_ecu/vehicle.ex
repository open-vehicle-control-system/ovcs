defmodule OvcsEcu.Vehicle do
  use GenServer
  require Logger
  alias OvcsEcu.{Inverter, BatteryManagementSystem, IgnitionLock, OvcsControllers.CarControlsController}

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{
      ignition_started: false
    }}
  end

  @impl true
  def handle_info(:timeout, state) do
    if (IgnitionLock.last_ignition_requested_at() < DateTime.utc_now() - 5000 && !state.ignition_started) do
      ^state = start_ignition(state)
    end

    if (ready_to_drive?()) do
      CarControlsController.throttle() |> Inverter.throttle()
    end

    {:noreply, state}
  end

  defp start_ignition(state) do
    # Will be trigger when key is in engineStart
    # Inverter 12 swicth on
    Inverter.on()
    BatteryManagementSystem.high_voltage_on()
    %{state | ignition_started: true}
  end

  defp ready_to_drive?() do
    Inverter.ready_to_drive?() && BatteryManagementSystem.ready_to_drive?()
  end

end
