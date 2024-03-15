defmodule VmsApiWeb.InverterChannel do
  use VmsApiWeb, :channel
  alias VmsCore.Inverter

  intercept ["update"]

  @impl true
  def join("inverter", payload, socket) do
    send(self(), :push_inverter_state)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_inverter_state)
    socket = %{socket | assigns: %{ timer: timer}}
    {:ok, socket}
  end

  @impl true
  def handle_info(:push_inverter_state, socket) do
    inverter_state = Inverter.inverter_state()
    push(socket, "updated", inverter_state)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, socket) do
    {:ok, _} = :timer.cancel(socket.assigns.timer)
  end
end
