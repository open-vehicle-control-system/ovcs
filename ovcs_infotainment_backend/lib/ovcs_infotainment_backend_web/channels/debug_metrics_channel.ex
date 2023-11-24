defmodule OvcsInfotainmentBackendWeb.DebugMetricsChannel do
  use Phoenix.Channel

  alias OvcsInfotainmentBackend.VehicleStateManager

  intercept ["update"]

  def join("debug-metrics", _message, socket) do
    IO.inspect "Socket connected"
    send(self(), :init)
    {:ok, socket}
  end

  def handle_info(:init, socket) do
    IO.inspect "Channel INIT"
    signals = VehicleStateManager.signals()
    push(socket, "updated", render_metrics(signals))
    {:noreply, socket}
  end

  def handle_out("update", signals, socket) do
    IO.inspect "Channel OUT"
    push(socket, "updated", render_metrics(signals))
    {:noreply, socket}
  end

  defp render_metrics(signals) do
    %{
      metrics: signals  |> Map.values() |> Enum.map(fn(signal) ->
        render_metric(signal)
      end)
    }
  end

  defp render_metric(signal) do
    %{
      id: signal.name,
      type: "metric",
      attributes: %{
        name: signal.name,
        kind: signal.kind,
        origin: signal.origin,
        value: signal.value,
        unit: signal.unit
      }
    }
  end
end
