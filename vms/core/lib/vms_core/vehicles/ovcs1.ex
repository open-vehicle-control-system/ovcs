defmodule VmsCore.Vehicles.OVCS1 do
  use GenServer
  require Logger
  alias VmsCore.Bus
  alias Cantastic.ReceivedFrameWatcher

  @loop_period 10

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Bus.subscribe("messages")
    :ok = ReceivedFrameWatcher.subscribe(:ovcs, ["controls_controller_alive", "front_controller_alive", "rear_controller_alive"], self())
    :ok = ReceivedFrameWatcher.subscribe(:polo_drive, "abs_status", self())
    enable_watchers()
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      ready_to_drive: false,
      contact: :off,
      ignition_started: false,
      high_voltage_contactors_ready_to_drive: false,
      inverter_ready_to_drive: false,
      braking_system_ready_to_drive: false,
      abs_watcher_enabled: false,
      vms_status: "ok",
      failed_frames: %{},
      frame_emitters: %{
        "abs_status"                => "ABS Ctrl",
        "controls_controller_alive" => "Controls Ctrl",
        "front_controller_alive"    => "Front Ctrl",
        "rear_controller_alive"     => "Rear Ctrl"
      }
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> update_igntion_started()
      |> check_ready_to_drive()
      |> update_frame_watchers()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: VmsCore.VwPolo.IgnitionLock}, state) do
    {:noreply, %{state | contact: contact}}
  end
  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: VmsCore.HighVoltageContactors}, state) do
    {:noreply, %{state | high_voltage_contactors_ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: VmsCore.NissanLeaf.Em57.Inverter}, state) do
    {:noreply, %{state | inverter_ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: VmsCore.Bosch.IboosterGen2}, state) do
    {:noreply, %{state | braking_system_ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  @impl true
  def handle_info({:handle_missing_frame,  network_name, frame_name}, state) do
    case state.failed_frames[frame_name] do
      nil ->
        Logger.warning("Frame #{network_name}.#{frame_name} not received anymore")
        state = state
          |> put_in([:vms_status], "failure")
          |> put_in([:failed_frames, frame_name], %{emitter: state.frame_emitters[frame_name]})
          {:noreply, state}
      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:enable_watchers, state) do
    :ok = ReceivedFrameWatcher.enable(:ovcs, ["controls_controller_alive", "rear_controller_alive", "front_controller_alive"])
    {:noreply, state}
  end

  defp update_igntion_started(state) do
    case {state.ignition_started, state.contact} do
      {false, :start} ->
        IO.inspect "START------------------------------------"
        %{state | ignition_started: true}
      {true, :off} ->
        IO.inspect "STOP------------------------------------"
        %{state | ignition_started: false}
      _ ->
        IO.inspect state
        state
    end
  end

  defp check_ready_to_drive(state) do
    #IO.inspect "ign: #{state.ignition_started}, HVC: #{state.high_voltage_contactors_ready_to_drive}, INV: #{state.inverter_ready_to_drive}, BRK: #{state.braking_system_ready_to_drive}"
    IO.inspect state
    ready_to_drive = state.ignition_started &&
      state.high_voltage_contactors_ready_to_drive &&
      state.inverter_ready_to_drive &&
      state.braking_system_ready_to_drive
    %{state | ready_to_drive: ready_to_drive}
  end

  defp update_frame_watchers(state) do
    case {state.contact, state.abs_watcher_enabled} do
      {:on, false} ->
        ReceivedFrameWatcher.enable(:polo_drive, "abs_status")
        %{state | abs_watcher_enabled: true}
      {:off, true} ->
        ReceivedFrameWatcher.disable(:polo_drive, "abs_status")
        %{state | abs_watcher_enabled: false}
      _ ->
        state
    end
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :vms_status, value: state.vms_status, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :failed_frames, value: state.failed_frames, source: __MODULE__})
    state
  end

  defp enable_watchers() do
    Process.send_after(self(), :enable_watchers, 5000)
  end
end
