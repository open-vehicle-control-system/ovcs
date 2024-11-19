defmodule VmsApiWeb.MetricsChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Metrics
  alias VmsCore.Components.OVCS.SteeringColumn

  intercept ["update"]

  @impl true
  def join("metrics", payload, socket) do
    send(self(), :push_metrics)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_metrics)
    {:ok, socket |> assign(:timer, timer)}
  end

  @impl true
  def handle_info(:push_metrics, socket) do
    {:ok, steering} =  Metrics.metrics(SteeringColumn)
    metrics = %{
      SteeringColumn => steering
    }
    view = VmsApiWeb.Api.MetricsJSON.render("metrics.json", %{metrics: metrics})
    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
