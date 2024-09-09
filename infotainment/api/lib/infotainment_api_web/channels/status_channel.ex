defmodule InfotainmentApiWeb.StatusChannel do
  use Phoenix.Channel
  require Logger

  alias InfotainmentCore.ComponentsAlive
  alias InfotainmentCore.ContactorsStatus

  intercept ["update"]

  def join("status", payload, socket) do
    send(self(), :push_status)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_status)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_status, socket) do
    {:ok, components_alive} = ComponentsAlive.status()
    {:ok, contactors_status} = ContactorsStatus.status()
    merge = Map.merge(components_alive, contactors_status)
    view = InfotainmentApiWeb.Api.StatusJSON.render("status.json", merge)
    push(socket, "updated", view)
    {:noreply, socket}
  end

  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
