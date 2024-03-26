defmodule VmsCore.Vehicle do
  use GenServer
  require Logger
  alias VmsCore.{Inverter, BatteryManagementSystem, IgnitionLock, Controllers.ControlsController}
  alias Decimal, as: D

  @loop_sleep 10
  @gear_shift_throttle_limit D.new("0.01")

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    loop()
    {:ok, %{
      ignition_started: false,
      selected_gear: "parking"
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> handle_ignition()
      |> handle_gear()
      |> handle_throttle()
      |> handle_rotation_per_minute()
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
         {:ok, throttle}       <- ControlsController.throttle()
    do
      case {selected_gear, requested_gear, D.lt?(throttle, @gear_shift_throttle_limit)} do
        {"parking", "parking", _} -> state
        {"reverse", "reverse", _} -> state
        {"neutral", "neutral", _} -> state
        {"drive", "drive", _}     -> state
        {_, "parking", true}      -> select_gear("parking", state)
        {_, "reverse", true}      -> select_gear("reverse", state)
        {"neutral", "drive", _}   -> select_gear("drive", state)
        {_, "drive", true}        -> select_gear("drive", state)
        {_, "neutral", _}         -> select_gear("neutral", state)
        _                         -> state
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
    case ready_to_drive?(state) do
      true -> apply_throttle(state)
      _    -> state
    end
  end

  defp select_gear(gear, state) do
    :ok = ControlsController.select_gear(gear)
    %{state | selected_gear: gear}
  end

  defp apply_throttle(state) do
    with {:ok, throttle} <- ControlsController.throttle(),
         :ok             <- Inverter.throttle(throttle, state.selected_gear)
    do
      state
    else
      :unexpected -> :unexpected
    end
  end

  defp start_ignition(state) do
    with :ok <- Inverter.on(),
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
    state.ignition_started && bms_ready && inverter_ready
  end

  defp shutdown(state) do
    with :ok <- Inverter.off(),
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

  # ---- Test functions ----
  def test_shutdown() do
    :ok = Inverter.off()
    :ok = BatteryManagementSystem.high_voltage_off()
  end

  def test_key_status() do
    IgnitionLock.key_status()
  end

  def test_ignition() do
    :ok = Inverter.on()
    :ok = BatteryManagementSystem.high_voltage_on()
  end

  def test_enable_calibration_mode() do
    :ok = ControlsController.enable_calibration_mode()
  end

  def test_disable_calibration_mode() do
    :ok = ControlsController.disable_calibration_mode()
  end
end
