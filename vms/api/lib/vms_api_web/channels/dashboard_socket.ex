defmodule VmsApiWeb.DashboardSocket do
  use Phoenix.Socket

  channel "network-interfaces", VmsApiWeb.NetworkInterfacesChannel
  channel "metrics", VmsApiWeb.MetricsChannel

  @impl Phoenix.Socket
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil
end
