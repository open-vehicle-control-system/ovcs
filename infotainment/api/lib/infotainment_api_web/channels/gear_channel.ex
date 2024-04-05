defmodule InfotainmentApiWeb.GearChannel do
  use Phoenix.Channel
  require Logger

  alias InfotainmentCore.Status

  intercept ["update"]

  def join("gear", payload, socket) do
    send(self(), :push_selected_gear)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_selected_gear)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_selected_gear, socket) do
    {:ok, gear} = Status.selected_gear()
    push(socket, "updated", %{gear: gear})
    {:noreply, socket}
  end

  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
