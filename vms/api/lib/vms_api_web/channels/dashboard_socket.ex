defmodule VmsApiWeb.DashboardSocket do
  use Phoenix.Socket

  channel "network-interfaces", VmsApiWeb.NetworkInterfacesChannel
  channel "metrics", VmsApiWeb.MetricsChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
