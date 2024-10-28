defmodule VintageNetEthernet do
  @moduledoc """
  Support for common wired Ethernet interface configurations

  Configurations for this technology are maps with a `:type` field set to
  `VintageNetEthernet`. The following additional fields are supported:

  * `:ipv4` - IPv4 options. See VintageNet.IP.IPv4Config.
  * `:dhcpd` - DHCP daemon options if running a static IP configuration. See
    VintageNet.IP.DhcpdConfig.
  * `:mac_address` - A MAC address string or an MFArgs tuple. VintageNet will
    set the MAC address of the network interface to the value specified. If an
    MFArgs tuple is passed, VintageNet will `apply` it and use the return value
    as the address.

  An example DHCP configuration is:

  ```elixir
  %{type: VintageNetEthernet, ipv4: %{method: :dhcp}}
  ```

  An example static IP configuration is:

  ```elixir
  %{
    type: VintageNetEthernet,
    ipv4: %{
      method: :static,
      address: {192, 168, 0, 5},
      prefix_length: 24,
      gateway: {192, 168, 0, 1}
    }
  }
  ```
  """
  @behaviour VintageNet.Technology

  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP.{DhcpdConfig, IPv4Config}
  alias VintageNetEthernet.Cookbook
  alias VintageNetEthernet.MacAddress

  require Logger

  @impl VintageNet.Technology
  def normalize(%{type: __MODULE__} = config) do
    config
    |> normalize_mac_address()
    |> IPv4Config.normalize()
    |> DhcpdConfig.normalize()
  end

  defp normalize_mac_address(%{mac_address: mac_address} = config) do
    if MacAddress.valid?(mac_address) or mfargs?(mac_address) do
      config
    else
      raise ArgumentError, "Invalid MAC address #{inspect(mac_address)}"
    end
  end

  defp normalize_mac_address(config), do: config

  defp mfargs?({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: true
  defp mfargs?(_), do: false

  @impl VintageNet.Technology
  def to_raw_config(ifname, %{type: __MODULE__} = config, opts) do
    normalized_config = normalize(config)

    %RawConfig{
      ifname: ifname,
      type: __MODULE__,
      source_config: normalized_config,
      required_ifnames: [ifname]
    }
    |> add_mac_address_config(normalized_config)
    |> IPv4Config.add_config(normalized_config, opts)
    |> DhcpdConfig.add_config(normalized_config, opts)
  end

  defp add_mac_address_config(raw_config, %{mac_address: mac_address}) do
    resolved_mac = resolve_mac(mac_address)

    if MacAddress.valid?(resolved_mac) do
      new_up_cmds =
        raw_config.up_cmds ++
          [{:run, "ip", ["link", "set", raw_config.ifname, "address", resolved_mac]}]

      %{raw_config | up_cmds: new_up_cmds}
    else
      Logger.warning(
        "vintage_net_ethernet: ignoring invalid MAC address '#{inspect(resolved_mac)}'"
      )

      raw_config
    end
  end

  defp add_mac_address_config(raw_config, _config) do
    raw_config
  end

  defp resolve_mac({m, f, args}) do
    apply(m, f, args)
  rescue
    e -> {:error, e}
  end

  defp resolve_mac(mac_address), do: mac_address

  @impl VintageNet.Technology
  def ioctl(_ifname, _command, _args) do
    {:error, :unsupported}
  end

  @impl VintageNet.Technology
  def check_system(_opts) do
    # TODO
    :ok
  end

  @spec quick_configure(VintageNet.ifname()) :: :ok | {:error, term()}
  def quick_configure(ifname \\ "eth0") do
    with {:ok, config} <- Cookbook.dynamic_ipv4() do
      VintageNet.configure(ifname, config)
    end
  end
end
