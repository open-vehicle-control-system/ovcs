defmodule VintageNetEthernet.Cookbook do
  @moduledoc """
  Recipes for common wired Ethernet configurations
  """

  @doc """
  Return a configuration for connecting to Ethernet network with a DHCP server
  """
  @spec dynamic_ipv4() :: {:ok, %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}
  def dynamic_ipv4() do
    {:ok, %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}}
  end
end
