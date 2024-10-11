defmodule VmsApiWeb.SteeringChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Metrics
  alias VmsCore.Components.Bosch.LWS

  intercept ["update"]

  @impl true
  def join("steering", payload, socket) do
    send(self(), :push_steering_state)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_steering_state)
    {:ok, socket |> assign(:timer, timer)}
  end

  @impl true
  def handle_info(:push_steering_state, socket) do
    {:ok, lws_status} = Metrics.metrics(LWS)
    view = VmsApiWeb.Api.SteeringJSON.render("steering.json", %{lws_status: lws_status})
    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
