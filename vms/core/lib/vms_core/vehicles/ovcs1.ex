defmodule VmsCore.Vehicles.OVCS1 do
  @moduledoc """
    Implements the OVCS1 specific logic (when is the vehicle ready, ...)
  """
  use GenServer
  require Logger
  alias VmsCore.{Bus, Status}
  alias VmsCore.Components.{
    Bosch.IBoosterGen2,
    Nissan.LeafZE0.Inverter,
    OVCS.HighVoltageContactors,
    Volkswagen.Polo9N.IgnitionLock,
  }
  alias VmsCore.Vehicles.OVCS1.{FrontController, ControlsController, RearController}

  @loop_period 10

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    Process.send_after(self(), :finish_boot_period, 5000)
    {:ok, %{
      loop_timer: timer,
      ready_to_drive: false,
      contact: :off,
      ignition_started: false,
      high_voltage_contactors_ready_to_drive: false,
      inverter_ready_to_drive: false,
      braking_system_ready_to_drive: false,
      front_controller_status: nil,
      front_controller_is_alive: false,
      controls_controller_status: nil,
      controls_controller_is_alive: false,
      rear_controller_status: nil,
      rear_controller_is_alive: false,
      booting: true,
      resetting: false,
      vms_status: "OK",
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> update_igntion_started()
      |> compute_ready_to_drive()
      |> compute_vms_status()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: IgnitionLock}, state) do
    {:noreply, %{state | contact: contact}}
  end
  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: HighVoltageContactors}, state) do
    {:noreply, %{state | high_voltage_contactors_ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: Inverter}, state) do
    {:noreply, %{state | inverter_ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{name: :ready_to_drive, value: ready_to_drive, source: IBoosterGen2}, state) do
    {:noreply, %{state | braking_system_ready_to_drive: ready_to_drive}}
  end
  def handle_info(%Bus.Message{name: :status, value: status, source: FrontController}, state)  do
    {:noreply, %{state | front_controller_status: status}}
  end
  def handle_info(%Bus.Message{name: :is_alive, value: is_alive, source: FrontController}, state)  do
    {:noreply, %{state | front_controller_is_alive: is_alive}}
  end
  def handle_info(%Bus.Message{name: :status, value: status, source: ControlsController}, state)  do
    {:noreply, %{state | controls_controller_status: status}}
  end
  def handle_info(%Bus.Message{name: :is_alive, value: is_alive, source: ControlsController}, state)  do
    {:noreply, %{state | controls_controller_is_alive: is_alive}}
  end
  def handle_info(%Bus.Message{name: :status, value: status, source: RearController}, state)  do
    {:noreply, %{state | rear_controller_status: status}}
  end
  def handle_info(%Bus.Message{name: :is_alive, value: is_alive, source: RearController}, state)  do
    {:noreply, %{state | rear_controller_is_alive: is_alive}}
  end
  def handle_info(%Bus.Message{name: :resetting, value: resetting, source: Status}, state)  do
    {:noreply, %{state | resetting: resetting}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  def handle_info(:finish_boot_period, state) do # TODO, replace Bus ?
    {:noreply, %{state | booting: false}}
  end

  defp update_igntion_started(state) do
    case {state.ignition_started, state.contact} do
      {false, :start} ->
        %{state | ignition_started: true}
      {true, :off} ->
        %{state | ignition_started: false}
      _ ->
        state
    end
  end

  defp compute_ready_to_drive(state) do
    ready_to_drive = state.vms_status == "OK" &&
      state.ignition_started &&
      state.high_voltage_contactors_ready_to_drive &&
      state.inverter_ready_to_drive &&
      state.braking_system_ready_to_drive
    %{state | ready_to_drive: ready_to_drive}
  end

  defp  compute_vms_status(state) do
    vms_is_ok = state.booting || state.resetting || (
      state.vms_status == "OK" &&
      state.front_controller_is_alive &&
      state.controls_controller_is_alive &&
      state.rear_controller_is_alive &&
      state.front_controller_status == "OK" &&
      state.controls_controller_status == "OK" &&
      state.rear_controller_status == "OK"
      )
    case vms_is_ok do
      true -> %{state | vms_status: "OK"}
      false -> %{state | vms_status: "FAILURE"}
    end
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :vms_status, value: state.vms_status, source: __MODULE__})
    state
  end
end
