defmodule InfotainmentApiWeb.TemperatureChannel do
  use Phoenix.Channel
  require Logger

  alias InfotainmentCore.Temperature

  intercept ["update"]

  def join("temperature", payload, socket) do
    send(self(), :push_temperature)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_temperature)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  def handle_info(:push_temperature, socket) do
    {:ok, temperature} = Temperature.temperature()
    push(socket, "updated", temperature)
    {:noreply, socket}
  end

  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
