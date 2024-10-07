defmodule VmsApiWeb.ThrottleChannel do
  use VmsApiWeb, :channel

  intercept ["update"]

  @impl true
  def join("throttle", payload, socket) do
    send(self(), :push_car_controls_state)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_car_controls_state)
    {:ok, socket |> assign(:timer, timer)}
  end

  @impl true
  def handle_info(:push_car_controls_state, socket) do
    {:ok, throttle} =  VmsCore.Vehicles.Metrics.metrics(VmsCore.ThrottlePedal)
    view = VmsApiWeb.Api.ThrottleJSON.render("throttle.json", %{throttle: throttle})
    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
