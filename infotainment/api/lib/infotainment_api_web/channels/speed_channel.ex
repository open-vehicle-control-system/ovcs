defmodule InfotainmentApiWeb.SpeedChannel do
  use Phoenix.Channel
  require Logger

  alias InfotainmentCore.VehicleStateManager

  intercept ["update"]

  def join("speed", payload, socket) do
    send(self(), :push_speed)
    Logger.debug("Joined speed")
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_speed)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_speed, socket) do
    speed_metric = VehicleStateManager.get_speed()
    Logger.debug("Speed is #{speed_metric.speed}")
    push(socket, "updated", %{speed: speed_metric.speed, unit: speed_metric.unit})
    {:noreply, socket}
  end

  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
