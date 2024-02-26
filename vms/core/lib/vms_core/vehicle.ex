defmodule VmsCore.Vehicle do
  use GenServer
  require Logger
  alias VmsCore.{Inverter, BatteryManagementSystem, IgnitionLock, Controllers.ControlsController}

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
    state
  end

  defp handle_throttle(state) do
    case ready_to_drive?(state) do
      {true, true} -> apply_throttle(state)
      _            -> state
    end
  end

  defp apply_throttle(state) do
    ControlsController.throttle() |> Inverter.throttle()
    state
  end

  defp start_ignition(state) do
    IO.inspect "Start_ignition"
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
