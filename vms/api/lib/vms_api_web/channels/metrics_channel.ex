defmodule VmsApiWeb.MetricsChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Metrics

  intercept ["update"]

  @impl true
  def join("metrics", payload, socket) do
    socket = socket
      |> assign(:timer_interval, payload["interval"])
      |> assign(:timer, nil)
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
    assigns = case assigns.timer do
      nil ->
        {:ok, timer} = :timer.send_interval(assigns.timer_interval, :push_metrics)
        %{assigns | timer: timer}
      _ -> assigns
    end
    {:noreply, %{socket | assigns: assigns}}
  end

  @impl true
  def handle_in("unsubscribe", %{"module" => module, "key" => key}, %Phoenix.Socket{assigns: assigns} = socket) do
    module                 = module |> String.to_existing_atom
    key                    = key |> String.to_existing_atom
    {_metric_key, assigns} = assigns |> pop_in([:metrics, module, key])
    assigns = case assigns.metrics[module] == %{} do
      true ->
        {_module_name, assigns} = assigns |> pop_in([:metrics, module])
        assigns
      false -> assigns
    end
    assigns = cond do
      assigns.metrics == %{} && !is_nil(assigns.timer) ->
        {:ok, _} = :timer.cancel(assigns.timer)
        %{assigns | timer: nil}
      true -> assigns
    end
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
  def terminate(_, %Phoenix.Socket{assigns: %{timer: nil}}), do: nil
  def terminate(_, %Phoenix.Socket{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
