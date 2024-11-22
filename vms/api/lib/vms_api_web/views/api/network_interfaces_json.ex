defmodule VmsApiWeb.Api.NetworkInterfacesJSON do
  use VmsApiWeb, :view

  def render("network_interfaces.json", %{network_interfaces: network_interfaces}) do
    %{
      data: render_many(network_interfaces, __MODULE__, "network_interface.json", as: :network_interface)
    }
  end

  def render("network_interface.json",%{network_interface: network_interface}) do
    %{
      type: "networkInterface",
      id:    network_interface.interface,
      attributes: %{
        networkName: network_interface.network_name,
        interfaceName: network_interface.interface,
        bitrate: network_interface.bitrate,
        spiInterfaceName: network_interface.spi_interface_name,
        statistics: network_interface.statistics
      }
    }
  end
end
