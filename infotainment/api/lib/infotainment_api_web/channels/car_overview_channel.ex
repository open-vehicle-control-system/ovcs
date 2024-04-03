defmodule InfotainmentApiWeb.CarOverviewChannel do
  use Phoenix.Channel
  require Logger

  alias InfotainmentCore.VehicleStateManager

  intercept ["update"]

  def join("car-overview", payload, socket) do
    send(self(), :push_car_overview)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_car_overview)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_car_overview, socket) do
    {:ok, car_overview} = VehicleStateManager.get_car_overview()
    push(socket, "updated", car_overview)
    {:noreply, socket}
  end

  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
