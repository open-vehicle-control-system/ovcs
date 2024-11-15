defmodule VmsApiWeb.DashboardSocket do
  use Phoenix.Socket

  channel "throttle", VmsApiWeb.ThrottleChannel
  channel "steering", VmsApiWeb.SteeringChannel
  channel "network-interfaces", VmsApiWeb.NetworkInterfacesChannel
  channel "inverter", VmsApiWeb.InverterChannel
  channel "vehicle-information", VmsApiWeb.VehicleInformationChannel
  channel "system-status", VmsApiWeb.SystemStatusChannel


  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
