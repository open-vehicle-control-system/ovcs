defmodule VmsApiWeb.CarControlsSocket do
  use Phoenix.Socket

  channel "car-controls", VmsApiWeb.DashboardChannel
  channel "network-interfaces", VmsApiWeb.NetworkInterfacesChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
