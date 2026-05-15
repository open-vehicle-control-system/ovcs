defmodule <%= @module %>.Vms do
  @moduledoc """
  VMS-side vehicle GenServer — the example shows the shape your
  vehicle-specific state machine should take.

  Extend this module to track whatever state `<%= @display_name %>`'s VMS needs:
  - listen for CAN frames via `Cantastic.Receiver.subscribe/3`
  - listen for internal messages via `OvcsBus.subscribe/1`
  - decide `ready_to_drive` and `vms_status` on a periodic loop
  - broadcast state changes back on the bus for dashboards to pick up
  """
  use GenServer
  require Logger
  alias OvcsBus, as: Bus
  alias VmsCore.{Status}
  alias <%= @module %>.Vms.ExampleController

  @loop_period 20

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)

    {:ok,
     %{
       loop_timer: timer,
       ready_to_drive: false,
       vms_status: "OK",
       example_controller_is_alive: false,
       resetting: false
     }}
  end

  @impl true
  def handle_info(:loop, state) do
    state =
      state
      |> compute_ready_to_drive()
      |> compute_vms_status()
      |> broadcast()

    {:noreply, state}
  end

  # Example: the ExampleController generic controller publishes a liveness
  # signal on the bus. Track it as a piece of VMS state.
  def handle_info(%Bus.Message{name: :is_alive, value: alive, source: ExampleController}, state) do
    {:noreply, %{state | example_controller_is_alive: alive}}
  end

  # The built-in `VmsCore.Status` component broadcasts `resetting` while
  # a reset is in flight — don't flap `vms_status` during that window.
  def handle_info(%Bus.Message{name: :resetting, value: resetting, source: Status}, state) do
    {:noreply, %{state | resetting: resetting}}
  end

  # Catch-all for unrelated bus messages.
  def handle_info(%Bus.Message{}, state), do: {:noreply, state}

  defp compute_ready_to_drive(state) do
    %{state | ready_to_drive: state.example_controller_is_alive}
  end

  defp compute_vms_status(state) do
    ok? = state.resetting or state.example_controller_is_alive
    %{state | vms_status: if(ok?, do: "OK", else: "FAILURE")}
  end

  defp broadcast(state) do
    Bus.broadcast("messages", %Bus.Message{name: :ready_to_drive, value: state.ready_to_drive, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :vms_status, value: state.vms_status, source: __MODULE__})
    state
  end
end
