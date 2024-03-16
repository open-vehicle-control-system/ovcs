defmodule VmsApiWeb.NetworkInterfacesChannel do
  use VmsApiWeb, :channel

  intercept ["update"]

  @impl true
  def join("network-interfaces", _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_out("update", payload, socket) do
    push(socket, "updated", %{ attributes: %{interfaces: payload}})
    {:noreply, socket}
  end
end
