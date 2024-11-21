defmodule VmsApiWeb.MetricsChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Metrics

  intercept ["update"]

  @impl true
  def join("metrics", payload, socket) do
    send(self(), :push_metrics)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_metrics)
    socket = socket
      |> assign(:timer, timer)
      |> assign(:metrics, %{})
    {:ok,socket}
  end

  def handle_in("subscribe", %{"module" => module, "key" => key}, %Phoenix.Socket{assigns: assigns} = socket) do
    module = module |> String.to_existing_atom
    key   = key |> String.to_existing_atom
    assigns = case assigns.metrics[module] do
      nil -> assigns |> put_in([:metrics, module], %{})
      _ -> assigns
    end
    assigns = assigns |> put_in([:metrics, module, key], true)
    {:noreply, %{socket | assigns: assigns}}
  end

  @impl true
  def handle_in("unsubscribe", %{"module" => module, "key" => key}, %Phoenix.Socket{assigns: assigns} = socket) do
    module = module |> String.to_existing_atom
    key   = key |> String.to_existing_atom
    assigns = assigns |> pop_in([:metrics, module, key])
    {:noreply, %{socket | assigns: assigns}}
  end

  @impl true
  def handle_info(:push_metrics, socket) do
    {:ok, metrics} = Metrics.filtered_metrics(socket.assigns.metrics)
    view = VmsApiWeb.Api.MetricsJSON.render("metrics.json", %{metrics: metrics})
    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
