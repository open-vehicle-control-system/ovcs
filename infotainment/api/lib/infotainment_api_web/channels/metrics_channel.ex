defmodule InfotainmentApiWeb.MetricsChannel do
  use Phoenix.Channel
  require Logger

  intercept ["update"]

  @impl true
  def join("metrics", payload, socket) do
    socket =
      socket
      |> assign(:timer_interval, payload["interval"])
      |> assign(:timer, nil)
      |> assign(:metrics, [])

    {:ok, socket}
  end

  def handle_in(
        "subscribe",
        %{"module" => module, "key" => key},
        %Phoenix.Socket{assigns: assigns} = socket
      ) do
    module = module |> String.to_existing_atom()
    key = key |> String.to_existing_atom()
    metric = {module, key}

    assigns =
      case Enum.member?(assigns.metrics, metric) do
        true ->
          assigns

        false ->
          assigns = %{assigns | metrics: assigns.metrics ++ [metric]}

          case assigns.timer do
            nil ->
              {:ok, timer} = :timer.send_interval(assigns.timer_interval, :push_metrics)
              %{assigns | timer: timer}

            _ ->
              assigns
          end
      end

    {:noreply, %{socket | assigns: assigns}}
  end

  @impl true
  def handle_in(
        "unsubscribe",
        %{"module" => module, "key" => key},
        %Phoenix.Socket{assigns: assigns} = socket
      ) do
    module = module |> String.to_existing_atom()
    key = key |> String.to_existing_atom()
    metric = {module, key}
    assigns = %{assigns | metrics: Enum.reject(assigns.metrics, &(&1 == metric))}

    assigns =
      cond do
        assigns.metrics == [] && !is_nil(assigns.timer) ->
          {:ok, _} = :timer.cancel(assigns.timer)
          %{assigns | timer: nil}

        true ->
          assigns
      end

    {:noreply, %{socket | assigns: assigns}}
  end

  @impl true
  def handle_info(:push_metrics, socket) do
    metrics = fetch_metrics(socket.assigns.metrics)
    push(socket, "updated", %{data: metrics})
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %Phoenix.Socket{assigns: %{timer: nil}}), do: nil

  def terminate(_, %Phoenix.Socket{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end

  defp fetch_metrics(subscribed_metrics) do
    subscribed_metrics
    |> Enum.group_by(fn {module, _key} -> module end, fn {_module, key} -> key end)
    |> Enum.flat_map(fn {module, keys} ->
      {:ok, status} = module.status()

      Enum.map(keys, fn key ->
        %{
          module: module,
          key: key,
          value: Map.get(status, key)
        }
      end)
    end)
  end
end
