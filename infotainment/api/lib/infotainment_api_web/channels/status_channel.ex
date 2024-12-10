defmodule InfotainmentApiWeb.StatusChannel do
  use Phoenix.Channel
  require Logger

  alias InfotainmentCore.VehicleStatus

  intercept ["update"]

  def join("status", payload, socket) do
    send(self(), :push_status)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_status)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_status, socket) do
    {:ok, status} = VehicleStatus.status()
    view = InfotainmentApiWeb.Api.StatusJSON.render("status.json", status)
    push(socket, "updated", view)
    {:noreply, socket}
  end

  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
