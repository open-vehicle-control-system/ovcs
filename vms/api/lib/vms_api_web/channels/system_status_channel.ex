defmodule VmsApiWeb.SystemStatusChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Metrics
  alias VmsCore.Vehicles.OVCS1

  intercept ["update"]

  @impl true
  def join("system-status", payload, socket) do
    send(self(), :push_system_status_state)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_system_status_state)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  @impl true
  def handle_info(:push_system_status_state, socket) do
    {:ok, vehicle_status} = Metrics.metrics(OVCS1)
    view = VmsApiWeb.Api.SystemStatusStateJSON.render("system_status_state.json", %{vehicle_status: vehicle_status})
    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
