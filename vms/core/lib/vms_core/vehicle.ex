defmodule VmsCore.Vehicle do
  use GenServer
  require Logger
  alias VmsCore.{Inverter, BatteryManagementSystem, IgnitionLock, OvcsControllers.CarControlsController}

  @loop_sleep 5

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(_) do
    #loop() -> uncomment when loop is ready
    {:ok, %{
      ignition_started: false
    }}
  end

  @impl true
  def handle_info(:loop, state) do
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
    Inverter.on()
    BatteryManagementSystem.high_voltage_on()
    %{state | ignition_started: true}
  end

  defp ready_to_drive?() do
    Inverter.ready_to_drive?() && BatteryManagementSystem.ready_to_drive?()
  end

  defp loop do
    Process.send_after(self(), :loop, @loop_sleep)
  end

  def key_status() do
    IgnitionLock.key_status()
  end

  def test_ignition() do
    Inverter.on()
    BatteryManagementSystem.high_voltage_on()
  end

  def test_shutdown() do
    Inverter.off()
    BatteryManagementSystem.high_voltage_off()
  end

  def test_enable_calibration_mode() do
    CarControlsController.enable_calibration_mode()
  end

  def test_disable_calibration_mode() do
    CarControlsController.disable_calibration_mode()
  end

  def enable_debugger() do
    Mix.ensure_application!(:wx)
    Mix.ensure_application!(:runtime_tools)
    Mix.ensure_application!(:observer)
    :observer.start()
  end
end
