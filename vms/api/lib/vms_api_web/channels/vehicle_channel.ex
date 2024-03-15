defmodule VmsApiWeb.VehicleChannel do
  use VmsApiWeb, :channel
  alias VmsCore.{Vehicle, IgnitionLock, Abs}

  intercept ["update"]

  @impl true
  def join("vehicle", payload, socket) do
    send(self(), :push_vehicle_state)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_vehicle_state)
    socket       = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  @impl true
  def handle_info(:push_vehicle_state, socket) do
    with {:ok, selected_gear} <- Vehicle.selected_gear(),
         {:ok, speed}         <- Abs.speed(),
         {:ok, key_status}    <- IgnitionLock.key_status()
    do
      assigns = %{
        selected_gear: selected_gear,
        speed: speed,
        key_status: key_status
      }
      view = VmsApiWeb.Api.VehicleStateJSON.render("vehicle_state.json", assigns)
      push(socket, "updated", view)
      {:noreply, socket}
    else
      :unexpected -> :unexpected
    end
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
