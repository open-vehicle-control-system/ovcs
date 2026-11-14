defmodule VmsApiWeb.NetworkInterfacesChannel do
  @moduledoc "Streams CAN interface statistics at a validated dashboard refresh interval."
  use VmsApiWeb, :channel
  alias VmsApiWeb.RefreshInterval
  alias VmsCore.NetworkInterfaces

  intercept ["update"]

  @impl Phoenix.Channel
  def join("network-interfaces", payload, socket) do
    with {:ok, interval} <- RefreshInterval.fetch(payload) do
      send(self(), :push_network_interfaces)
      {:ok, timer} = :timer.send_interval(interval, :push_network_interfaces)
      {:ok, socket |> assign(:timer, timer)}
    end
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
