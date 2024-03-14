defmodule VmsApiWeb.CarControlsChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Controllers.ControlsController

  intercept ["update"]

  @impl true
  def join("car-controls", payload, socket) do
    send(self(), :push_car_controls_state)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_car_controls_state)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_car_controls_state, socket) do
    car_controls_state = ControlsController.car_controls_state()
    push(socket, "updated", car_controls_state)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", payload, socket) do
    {:reply, {:ok, payload}, socket}
  end

  @impl true
  def handle_in("shout", payload, socket) do
    broadcast(socket, "shout", payload)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, socket) do
    {:ok, _} = :timer.cancel(socket.assigns.timer)
  end
end
