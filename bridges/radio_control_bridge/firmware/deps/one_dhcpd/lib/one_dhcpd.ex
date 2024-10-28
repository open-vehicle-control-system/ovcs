defmodule OneDHCPD do
  @moduledoc """
  The One Address DHCP Server!

  This is a simple DHCP server for supplying IP addresses on point-to-point
  Ethernet links.  To use it, specify a static IPv4 address on the Ethernet
  interface and then start the server up.  OneDHCPD can supply an IPv4 address
  for you by calling `OneDHCPD.default_ip_address/1` that should minimize IP
  conflicts with the user's network and other OneDHCPD servers. This is the
  recommended approach.

  OneDHCPD is mostly used behinds the scenes with VintageNet. Here's an example
  for using it with a virtual USB ethernet interface:

  ```elixir
  iex> VintageNet.configure("usb0", %{type: VintageNetDirect})
  :ok
  ```

  The Nerves new project generator adds this configuration by default. If you'd
  like more information, see the
  [VintageNetDirect[(https://hexdocs.pm/vintage_net_direct/VintageNetDirect.html)
  documentation.
  """
  alias OneDHCPD.IPCalculator

  @doc """
  Return the default server IP address that would be used for the specified
  interface.
  """
  @spec default_ip_address(String.t()) :: :inet.ip4_address()
  def default_ip_address(ifname) do
    IPCalculator.default_subnet(ifname)
    |> IPCalculator.our_ip_address()
  end

  @doc """
  Return the subnet mask that goes along with default_ip_address/1.
  """
  @spec default_subnet_mask() :: :inet.ip4_address()
  def default_subnet_mask() do
    IPCalculator.mask()
  end
end
