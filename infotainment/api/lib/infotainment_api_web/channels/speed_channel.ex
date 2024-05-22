defmodule InfotainmentApiWeb.SpeedChannel do
  use Phoenix.Channel
  require Logger

  alias InfotainmentCore.Status

  intercept ["update"]

  def join("speed", payload, socket) do
    send(self(), :push_speed)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_speed)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_speed, socket) do
    {:ok, speed} = Status.speed()
    push(socket, "updated", %{speed: speed})
    {:noreply, socket}
  end

  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
