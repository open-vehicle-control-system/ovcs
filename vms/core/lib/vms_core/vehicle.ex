defmodule VmsCore.Vehicle do
  use GenServer
  require Logger
  alias VmsCore.{Inverter, BatteryManagementSystem, Abs, IgnitionLock, Controllers.ControlsController}

  @loop_sleep 10

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
      |> handle_rpm()
    loop()
    {:noreply, state}
  end

  defp handle_ignition(state) do
    case {state.ignition_started, IgnitionLock.key_status()} do
      {false, "start_engine"} -> start_ignition(state)
      {true, "off"}           -> shutdown(state)
      {true, "key_engaged"}   -> shutdown(state)
      _                       -> state
    end
  end

  defp handle_gear(state) do
    requested_gear = ControlsController.requested_gear()
    selected_gear  = state.selected_gear
    speed          = Abs.speed()
    throttle       = ControlsController.throttle()
    case {selected_gear, requested_gear, speed < 1.0, throttle < 0.1} do # TODO check safe throttle
      {"parking", "parking", _, _} -> state
      {"reverse", "reverse", _, _} -> state
      {"neutral", "neutral", _, _} -> state
      {"drive", "drive", _, _}     -> state
      {_, "parking", true, true}   -> select_gear("parking", state)
      {_, "reverse", true, true}   -> select_gear("reverse", state)
      {"neutral", "drive", _, _}   -> select_gear("drive", state)
      {_, "drive", true, true}     -> select_gear("drive", state)
      {_, "neutral", _, _}         -> select_gear("neutral", state)
      _                            -> state
    end
  end

  defp handle_rpm(state) do
    :ok = Inverter.rpm() |> abs() |> VmsCore.VwPolo.Engine.rpm()
    state
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
    :ok = ControlsController.throttle() |> Inverter.throttle(state.selected_gear)
    state
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
    state.ignition_started && Inverter.ready_to_drive?() && BatteryManagementSystem.ready_to_drive?()
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
    ControlsController.enable_calibration_mode()
  end

  def test_disable_calibration_mode() do
    ControlsController.disable_calibration_mode()
  end

  def enable_debugger() do
    Mix.ensure_application!(:wx)
    Mix.ensure_application!(:runtime_tools)
    Mix.ensure_application!(:observer)
    :observer.start()
  end
end
