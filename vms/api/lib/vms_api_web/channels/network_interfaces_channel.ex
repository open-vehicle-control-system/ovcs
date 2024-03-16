defmodule VmsApiWeb.NetworkInterfacesChannel do
  use VmsApiWeb, :channel

  intercept ["update"]

  @impl true
  def join("network-interfaces", _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_out("update", payload, socket) do
    view = VmsApiWeb.Api.NetworkInterfacesJSON.render("network_interfaces.json", %{interfaces: payload})
    push(socket, "updated", view)
    {:noreply, socket}
  end
end
