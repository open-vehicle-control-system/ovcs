defmodule VmsApiWeb.VehicleChannel do
  use VmsApiWeb, :channel
  alias VmsCore.{Vehicle, IgnitionLock, Abs}

  intercept ["update"]

  @impl true
  def join("vehicle", payload, socket) do
    send(self(), :push_vehicle_state)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_vehicle_state)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  @impl true
  def handle_info(:push_vehicle_state, socket) do
    vehicle_state = %{
      selected_gear: Vehicle.selected_gear(),
      speed: Abs.speed(),
      key_status: IgnitionLock.key_status()
    }
    push(socket, "updated", vehicle_state)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, socket) do
    {:ok, _} = :timer.cancel(socket.assigns.timer)
  end
end
