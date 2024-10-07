defmodule VmsCore.Vehicles.OVCS1 do
  use GenServer
  alias VmsCore.Bus

  @loop_period 10

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{contact_source: contact_source}) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      ready_to_drive: false,
      contact: :off,
      ignition_started: false,
      contact_source: contact_source,
      high_voltage_contactors_ready_to_drive: false,
      inverter_ready_to_drive: false,
      braking_system_ready_to_drive: false
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state
      |> update_igntion_started()
      |> check_ready_to_drive()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :contact, value: contact, source: source}, state) when source == state.contact_source do
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

  defp check_ready_to_drive(state) do
    ready_to_drive = state.ignition_started &&
      state.high_voltage_contactors_ready_to_drive &&
      state.inverter_ready_to_drive &&
      state.braking_system_ready_to_drive
    %{state | ready_to_drive: ready_to_drive}
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
    state
  end
end
