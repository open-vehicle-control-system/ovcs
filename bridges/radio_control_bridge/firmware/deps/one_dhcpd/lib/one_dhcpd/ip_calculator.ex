defmodule OneDHCPD.IPCalculator do
  @moduledoc """
  This module handles IP address calculations.

  The most involved of the calculations is the determination of a good IP
  subnet to use. OneDHCPD subnet tries for the following:

  * Subnets should be the same across reboots (convenience and no surprise conflicts)
  * Support running on more than one interface (unique subnets on device)
  * Support hosts than have more than one device (unique subnets between
    devices)
  * Don't conflict with the IPs used on the host for Internet

  The algorithm here is to hash the hostname (uniqueness between devices
  assuming the hostname is unique) and the network interface (uniqueness on
  device). Then use those bits to pick a subnet in the 172.31.0.0/16
  private address range. That private range was picked arbitrarily since
  10.0.0.0/8 and 192.168.0.0/16 ranges are commonly used. 172.18.0.0/16
  is used by Docker.
  """

  @doc """
  Return the subnet mask.

  Currently this is hardcoded to a /30 network.
  """
  @spec mask() :: :inet.ip4_address()
  def mask(), do: {255, 255, 255, 252}

  @doc """
  Return the prefix length that OneDHCPD uses.
  """
  @spec prefix_length() :: 30
  def prefix_length(), do: 30

  @doc """
  Calculate the default subnet for the specified Ethernet interface.
  """
  @spec default_subnet(String.t()) :: :inet.ip4_address()
  def default_subnet(ifname) do
    {:ok, hostname} = :inet.gethostname()
    default_subnet(ifname, to_string(hostname))
  end

  @doc """
  Calculate the default subnet for the specified Ethernet interface
  and specify the hostname manually.
  """
  @spec default_subnet(String.t(), String.t()) :: :inet.ip4_address()
  def default_subnet(ifname, hostname) do
    # compute 14 random bits for the subnet
    <<c::8, d::6, _leftovers::bits>> = :crypto.hash(:md5, [hostname, ifname])

    # Build the IP address in 172.31.c.d/30
    {172, 31, c, d * 4}
  end

  @doc """
  Return our IP address. This is the one that should be set
  as a static address on the interface if using the defaults.
  """
  @spec our_ip_address(:inet.ip4_address()) :: :inet.ip4_address()
  def our_ip_address({a, b, c, d}) do
    {a, b, c, d + 1}
  end

  @doc """
  Return the IP address that's given out to the client.
  """
  @spec their_ip_address(:inet.ip4_address()) :: :inet.ip4_address()
  def their_ip_address({a, b, c, d}) do
    {a, b, c, d + 2}
  end
end
