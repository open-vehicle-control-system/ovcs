defmodule VmsApiWeb.SystemStatusChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Status

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
    {:ok, failed_frames} = Status.failed_frames()
    view = VmsApiWeb.Api.SystemStatusStateJSON.render("system_status_state.json", %{failed_frames: failed_frames})
    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
