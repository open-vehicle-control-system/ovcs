defmodule InfotainmentApiWeb.StatusChannel do
  use Phoenix.Channel
  require Logger

  intercept ["update"]

  def join("status", payload, socket) do
    send(self(), :push_status)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_status)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_status, socket) do
    vehicle = Application.fetch_env!(:infotainment_api, :vehicle)

    vehicles_module = Module.concat([InfotainmentCore, Vehicles, vehicle])
    json_module = Module.concat([InfotainmentApiWeb, Api, vehicle, StatusJSON])

    {:ok, status} = vehicles_module.status()
    view = json_module.render("status.json", status)
    push(socket, "updated", view)
    {:noreply, socket}
  end

  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
