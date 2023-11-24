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
        origin: signal.emitter,
        value: signal.value,
        unit: signal.unit
      }
    }
  end

  def metrics(signals) do
    %{
      metrics: [
        %{id: "1", type: "metric",  attributes: %{name: "speed", kind: "integer", unit: "m/s", origin: "abs", value: 14}},
        %{id: "2", type: "metric",  attributes: %{name: "frontLeftWheelSpeed", kind: "integer", unit: "m/s", origin: "abs", value: 14}},
        %{id: "3", type: "metric",  attributes: %{name: "frontRightWheelSpeed", kind: "integer", unit: "m/s", origin: "abs", value: 14}},
        %{id: "4", type: "metric",  attributes: %{name: "rearLeftWheelSpeed", kind: "integer", unit: "m/s", origin: "abs", value: 14}},
        %{id: "5", type: "metric",  attributes: %{name: "rearRightWheelSpeed", kind: "integer", unit: "m/s", origin: "abs", value: 14}},
        %{id: "6", type: "metric",  attributes: %{name: "rotationsPerMinute", kind: "integer", unit: "rpm", origin: "engine", value: 1460}},
        %{id: "7", type: "metric",  attributes: %{name: "coolingFuildTemp", kind: "integer", unit: "celcius", origin: "engine", value: 89}},
        %{id: "8", type: "metric",  attributes: %{name: "incarAirbagSystemOnline", kind: "boolean", origin: "airbag", value: true}},
        %{id: "9", type: "metric",  attributes: %{name: "passengerAirbagOnline", kind: "boolean", origin: "airbag", value: true}},
        %{id: "10", type: "metric", attributes: %{name: "handbrakeEngaged", kind: "boolean", origin: "handbrake", value: signals["handbrakeEngaged"] && signals["handbrakeEngaged"].value}},
        %{id: "11", type: "metric", attributes: %{name: "steeringPumpActive", kind: "boolean", origin: "steering_pump", value: true}},
        %{id: "12", type: "metric", attributes: %{name: "driverDoorOpen", kind: "boolean", origin: "doors", value: false}},
        %{id: "13", type: "metric", attributes: %{name: "frontPassengerDoorOpen", kind: "boolean", origin: "doors", value: false}},
        %{id: "14", type: "metric", attributes: %{name: "rearLeftPassengerDoorOpen", kind: "boolean", origin: "doors", value: false}},
        %{id: "15", type: "metric", attributes: %{name: "rearRightPassengerDoorOpen", kind: "boolean", origin: "doors", value: false}},
        %{id: "16", type: "metric", attributes: %{name: "trunkDoorOpen", kind: "boolean", origin: "doors", value: false}},
        %{id: "17", type: "metric", attributes: %{name: "warningLightsActive", kind: "boolean", origin: "lights", value: false}},
        %{id: "18", type: "metric", attributes: %{name: "beamActive", kind: "boolean", origin: "lights", value: true}}
      ]
    }
  end
end
