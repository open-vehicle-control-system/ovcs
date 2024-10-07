defmodule VmsApiWeb.InverterChannel do
  use VmsApiWeb, :channel

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
    {:ok, inverter_state} = VmsCore.Vehicles.Metrics.metrics(VmsCore.NissanLeaf.Em57.Inverter)
    view = VmsApiWeb.Api.InverterStateJSON.render("inverter_state.json", %{inverter_state: inverter_state})
    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl true
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
