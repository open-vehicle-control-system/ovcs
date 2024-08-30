defmodule VmsCore.Vehicle do
  use GenServer
  require Logger
  alias VmsCore.{Inverter, BatteryManagementSystem, IgnitionLock, Controllers.ControlsController, Status, Charger, BreakingSystem}
  alias Decimal, as: D

  @loop_sleep 10
  @gear_shift_throttle_limit D.new("0.05")
  @gear_shift_speed_limit D.new("1")
  @zero D.new(0)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    loop()
    {:ok, %{
      ignition_started: false,
      selected_gear: "parking",
      ready_to_drive?: false,
      allowed_discharge_power: @zero,
      allowed_charge_power: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> handle_ready_to_drive()
      |> handle_ignition()
      |> handle_gear()
      |> handle_throttle()
      |> handle_rotation_per_minute()
      |> handle_charge()
    loop()
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

  defp handle_gear(state) do
    with {:ok, requested_gear} <- gear_control_module().requested_gear(),
         selected_gear         <- state.selected_gear,
         {:ok, throttle}       <- ControlsController.throttle(),
         {:ok, speed}          <- VmsCore.VwPolo.Abs.speed()
    do
      throttle_near_zero = D.lt?(throttle, @gear_shift_throttle_limit)
      speed_near_zero    = D.abs(speed) |> D.lt?(@gear_shift_speed_limit)
      ready_to_drive     = state.ready_to_drive?
      case {selected_gear, requested_gear, throttle_near_zero && speed_near_zero, ready_to_drive} do
        {"parking", "parking", _, _} -> state
        {"reverse", "reverse", _, _} -> state
        {"neutral", "neutral", _, _} -> state
        {"drive", "drive", _, _}     -> state
        {_, "parking", true, _}      -> select_gear("parking", state)
        {_, "reverse", true, true}   -> select_gear("reverse", state)
        {_, "drive", true, true}     -> select_gear("drive", state)
        {_, "neutral", _, _}         -> select_gear("neutral", state)
        _                            -> state
      end
    else
      :unexpected -> :unexpected
    end
  end

  defp handle_rotation_per_minute(state) do
    with {:ok, rotation_per_minute} <- Inverter.rotation_per_minute(),
         :ok        <- abs(rotation_per_minute) |> VmsCore.VwPolo.Engine.rotation_per_minute()
    do
      state
    else
      :unexpected -> :unexpected
    end
  end

  defp handle_throttle(state) do
    case state.ready_to_drive? do
      true -> apply_throttle(state)
      _    -> state
    end
  end

  defp handle_charge(state) do
    with  {:ok, ac_voltage}                                    <- Charger.ac_voltage(),
          :ok                                                  <- BatteryManagementSystem.ac_input_voltage(ac_voltage),
          {:ok, allowed_charge_power, allowed_discharge_power} <- BatteryManagementSystem.allowed_power(),
          :ok                                                  <- Charger.maximum_power_for_charger(allowed_charge_power)
    do
      %{state |
        allowed_charge_power: allowed_charge_power,
        allowed_discharge_power: allowed_discharge_power
      }
    else
      :unexpected -> :unexpected
    end
  end

  defp handle_ready_to_drive(state) do
    ready_to_drive? = ready_to_drive?(state)
    case state.ready_to_drive? == ready_to_drive? do
      true  -> state
      false ->
        :ok = Status.ready_to_drive(ready_to_drive?)
        %{state | ready_to_drive?: ready_to_drive?}
    end
  end

  defp select_gear(gear, state) do
    :ok = ControlsController.select_gear(gear)
    %{state | selected_gear: gear}
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

  defp ready_to_drive?(state) do
    {:ok, bms_ready}      = BatteryManagementSystem.ready_to_drive?()
    {:ok, inverter_ready} = Inverter.ready_to_drive?()
    {:ok, breaking_system_ready} = BreakingSystem.ready_to_drive?()
    state.ignition_started && bms_ready && inverter_ready && breaking_system_ready
  end

  defp shutdown(state) do
    with :ok <- BreakingSystem.off(),
         :ok <- Inverter.off(),
         :ok <- BatteryManagementSystem.high_voltage_off()
    do
      %{state | ignition_started: false}
    else
      :unexpected -> :unexpected
    end
  end

  defp loop do
    Process.send_after(self(), :loop, @loop_sleep)
  end

  @impl true
  def handle_call(:selected_gear, _from, state) do
    {:reply, {:ok, state.selected_gear}, state}
  end

  def selected_gear() do
    GenServer.call(__MODULE__, :selected_gear)
  end

  defp gear_control_module() do
    Application.get_env(:vms_core, :gear_control_module)
  end
end
