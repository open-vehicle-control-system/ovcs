defmodule VmsApiWeb.Api.NetworkInterfacesJSON do
  use VmsApiWeb, :view

  def render("network_interfaces.json",%{interfaces: interfaces}) do
    %{
      type: "networkInterfaces",
      id:    "networkInterfaces",
      attributes: %{
        interfaces: interfaces
      }
    }
  end
end
