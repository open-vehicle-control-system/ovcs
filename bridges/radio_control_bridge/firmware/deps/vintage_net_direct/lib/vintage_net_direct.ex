defmodule VintageNetDirect do
  @moduledoc """
  Support for directly connected Ethernet configurations

  Direct Ethernet connections are those where the network connects only two
  devices. Examples include a virtual Ethernet interface being run over a USB
  cable. This is a popular Nerves configuration for development where the USB
  cable provides power and networking to a Raspberry Pi, Beaglebone or other
  "USB Gadget"-capable board. Another example would be a direct Ethernet
  connection between a device and a development computer.  Such a connection is
  handy when a router isn't readily available.

  The VintageNet Technology works by assigning a static IP address to the
  Ethernet interface on this side of the connection and running a DHCP server
  to assign an IP address to the other side of the cable.  IP addresses are
  computed based on the hostname and interface name. A /30 subnet is used for
  the two IP addresses for each side of the cable to try to avoid conflicts
  with IP subnets used on either computer. The DHCP server in use is very
  simple and assigns the same IP address every time.

  Note that many decisions were made to make this use case work well. If
  you're thinking about use cases with more than just the one cable and two
  endpoints, you'll want to look elsewhere.

  Configurations for this technology are maps with a `:type` field set to
  `VintageNetDirect`. `VintageNetDirect`-specific options are in a map under
  the `:vintage_net_direct` key (formerly the `:gadget` key). These include:

  * `:hostname` - if non-nil, this overrides the hostname used for computing
    a unique IP address for this interface. If unset, `:inet.gethostname/0`
    is used.

  Most users should specify the following configuration:

  ```elixir
  %{type: VintageNetDirect}
  ```
  """
  @behaviour VintageNet.Technology

  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP.IPv4Config

  @impl VintageNet.Technology
  def normalize(%{type: __MODULE__} = config) do
    normalized =
      get_specific_options(config)
      |> normalize_options()

    %{type: __MODULE__, vintage_net_direct: normalized}
  end

  defp get_specific_options(config) do
    Map.get(config, :vintage_net_direct) || Map.get(config, :gadget)
  end

  defp normalize_options(%{hostname: hostname}) when is_binary(hostname) do
    %{hostname: hostname}
  end

  defp normalize_options(_specific_config), do: %{}

  @impl VintageNet.Technology
  def to_raw_config(ifname, %{type: __MODULE__} = config, opts) do
    normalized_config = normalize(config)

    # Derive the subnet based on the ifname, but allow the user to force a hostname
    subnet =
      case normalized_config.vintage_net_direct do
        %{hostname: hostname} ->
          OneDHCPD.IPCalculator.default_subnet(ifname, hostname)

        _ ->
          OneDHCPD.IPCalculator.default_subnet(ifname)
      end

    ipv4_config = %{
      ipv4: %{
        method: :static,
        address: OneDHCPD.IPCalculator.our_ip_address(subnet),
        prefix_length: OneDHCPD.IPCalculator.prefix_length()
      }
    }

    %RawConfig{
      ifname: ifname,
      type: __MODULE__,
      source_config: normalized_config,
      required_ifnames: [ifname],
      child_specs: [{OneDHCPD.Server, [ifname, [subnet: subnet]]}]
    }
    |> IPv4Config.add_config(ipv4_config, opts)
  end

  @impl VintageNet.Technology
  def ioctl(_ifname, _command, _args) do
    {:error, :unsupported}
  end

  @impl VintageNet.Technology
  def check_system(_opts) do
    # TODO
    :ok
  end
end
