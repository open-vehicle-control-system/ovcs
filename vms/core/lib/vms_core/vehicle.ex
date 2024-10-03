defmodule VmsCore.Vehicle do
  use GenServer
  require Logger
  alias VmsCore.{Inverter, BatteryManagementSystem, IgnitionLock, Controllers.ControlsController}
  alias Decimal, as: D

  @loop_sleep 10
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> handle_ignition()
      |> handle_throttle()
    #loop()
    {:noreply, state}
  end

  defp handle_ignition(state) do
    {:ok, key_status} = IgnitionLock.key_status()
    case {state.ignition_started, key_status} do
      {false, "start_engine"} -> start_ignition(state)
      {true, "off"}           -> shutdown(state)
      {true, "key_engaged"}   -> shutdown(state)
      _                       -> state
    end
  end

  defp handle_throttle(state) do
    case state.ready_to_drive? && !state.demo_mode do
      true -> apply_throttle(state)
      _    -> state
    end
  end

  defp apply_throttle(state) do
    with {:ok, throttle} <- ControlsController.throttle(),
         :ok             <- Inverter.throttle(throttle, state.selected_gear, state.allowed_discharge_power)
    do
      state
    else
      :unexpected -> :unexpected
    end
  end

  defp start_ignition(state) do
    with :ok <- BreakingSystem.on(),
         :ok <- Inverter.on(),
         :ok <- BatteryManagementSystem.high_voltage_on()
    do
      %{state | ignition_started: true}
    else
      :unexpected -> :unexpected
    end
  end

  defp shutdown(state) do
    with :ok <- VmsCore.VwPolo.PowerSteeringPump.off(),
         :ok <- BreakingSystem.off(),
         :ok <- Inverter.off(),
         :ok <- BatteryManagementSystem.high_voltage_off()
    do
      %{state | ignition_started: false}
    else
      :unexpected -> :unexpected
    end
  end

end
