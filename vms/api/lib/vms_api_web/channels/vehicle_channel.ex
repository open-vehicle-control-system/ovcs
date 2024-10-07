defmodule VmsApiWeb.VehicleChannel do
  use VmsApiWeb, :channel

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
    with {:ok, %{selected_gear: selected_gear}} <- VmsCore.Vehicles.Metrics.metrics(VmsCore.GearSelector),
         {:ok, %{speed: speed}}                 <- VmsCore.Vehicles.Metrics.metrics(VmsCore.VwPolo.Abs),
         {:ok, %{contact: contact}}             <- VmsCore.Vehicles.Metrics.metrics(VmsCore.VwPolo.IgnitionLock)
    do
      assigns = %{
        selected_gear: selected_gear,
        speed: speed,
        key_status: contact
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
