defmodule VmsApiWeb.CarControlsChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Controllers.ControlsController

  intercept ["update"]

  @impl true
  def join("car-controls", payload, socket) do
    send(self(), :push_car_controls_state)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_car_controls_state)
    {:ok, socket |> assign(:timer, timer)}
  end

  @impl true
  def handle_info(:push_car_controls_state, socket) do
    {:ok, car_controls} = ControlsController.car_controls_state()
    view = VmsApiWeb.Api.CarControlsJSON.render("car_controls.json", %{car_controls: car_controls})
    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
