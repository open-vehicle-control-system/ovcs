defmodule VmsApiWeb.NetworkInterfacesChannel do
  use VmsApiWeb, :channel
  alias VmsCore.NetworkInterfaces

  intercept ["update"]

  @impl Phoenix.Channel
  def join("network-interfaces", payload, socket) do
    send(self(), :push_network_interfaces)
    {:ok, timer} = :timer.send_interval(payload["interval"], :push_network_interfaces)
    {:ok, socket |> assign(:timer, timer)}
  end

  @impl Phoenix.Channel
  def handle_info(:push_network_interfaces, socket) do
    {:ok, network_interfaces} = NetworkInterfaces.network_interfaces()

    view =
      VmsApiWeb.Api.NetworkInterfacesJSON.render("network_interfaces.json", %{
        network_interfaces: network_interfaces
      })

    push(socket, "updated", view)
    {:noreply, socket}
  end

  @impl Phoenix.Channel
  def terminate(_, %{assigns: %{timer: timer}}) do
    {:ok, _} = :timer.cancel(timer)
  end
end
