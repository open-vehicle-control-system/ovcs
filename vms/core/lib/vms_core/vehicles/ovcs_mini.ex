defmodule VmsCore.Vehicles.OVCSMini do
  @moduledoc """
    Implements the OVCS Mini specific logic (when is the vehicle ready, ...)
  """
  use GenServer
  require Logger
  alias VmsCore.{Bus, Status}
  alias VmsCore.Vehicles.OVCSMini.MainController

  @loop_period 10

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @impl true
  def init(_) do
    Bus.subscribe("messages")
    Process.send_after(self(), :finish_boot_period, 5000)
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      ready_to_drive: true,
      vms_status: "OK",
      main_controller_status: nil,
      main_controller_is_alive: false,
      booting: true,
      resetting: false,
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> check_ready_to_drive()
      |> compute_vms_status()
      |> emit_metrics()

    {:noreply, state}
  end

  def handle_info(%Bus.Message{name: :status, value: status, source: MainController}, state)  do
    {:noreply, %{state | main_controller_status: status}}
  end
  def handle_info(%Bus.Message{name: :is_alive, value: is_alive, source: MainController}, state)  do
    {:noreply, %{state | main_controller_is_alive: is_alive}}
  end
  def handle_info(%Bus.Message{name: :resetting, value: resetting, source: Status}, state)  do
    {:noreply, %{state | resetting: resetting}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
  end

  def handle_info(:finish_boot_period, state) do
    {:noreply, %{state | booting: false}}
  end


  defp  compute_vms_status(state) do
    vms_is_ok = state.booting || state.resetting || (
      state.vms_status == "OK" &&
      state.main_controller_is_alive &&
      state.main_controller_status == "OK"
      )
    case vms_is_ok do
      true -> %{state | vms_status: "OK"}
      false -> %{state | vms_status: "FAILURE"}
    end
  end

  defp check_ready_to_drive(state) do
    #TODO
    state
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :vms_status, value: state.vms_status, source: __MODULE__})
    state
  end
end
