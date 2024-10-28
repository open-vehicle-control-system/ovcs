defmodule MdnsLite.Options do
  @moduledoc """
  MdnsLite options

  MdnsLite is usually configured in a project's application environment
  (`config.exs`) as follows:

  ```elixir
  config :mdns_lite,
    hosts: [:hostname, "nerves"],
    ttl: 120,

    instance_name: "mDNS Lite Device",

    services: [
      %{
        id: :web_server,
        protocol: "http",
        transport: "tcp",
        port: 80,
        txt_payload: ["key=value"]
      },
      %{
        id: :ssh_daemon,
        instance_name: "More particular mDNS Lite Device"
        protocol: "ssh",
        transport: "tcp",
        port: 22
      }
    ]
  ```

  The configurable keys are:

  * `:hosts` - A list of hostnames to respond to. Normally this would be set to
    `:hostname` and `mdns_lite` will advertise the actual hostname with `.local`
    appended.
  * `:ttl` - The default mDNS record time-to-live. The default of 120
    seconds is probably fine for most use. See [RFC 6762 - Multicast
    DNS](https://tools.ietf.org/html/rfc6762) for considerations.
  * `instance_name` - A user friendly name that will be used as the name for this
    device's advertised service(s). Per RFC6763 Appendix C, this should describe
     the user-facing purpose or description of the device, and should not be
     considered a unique identifier. For example, 'Nerves Device' and 'MatCo
     Laser Printer Model CRM-114' are good choices here.  If instance_name is not
     defined it defaults to the first entry in the `hosts` list
  * `:excluded_ifnames` - A list of network interfaces names to ignore. By
    default, `mdns_lite` will ignore loopback and cellular network interfaces.
  * `:ipv4_only` - Set to `true` to only respond on IPv4 interfaces. Since IPv6
    isn't fully supported yet, this is the default. Note that it's still
    possible to get AAAA records when using IPv4.
  * `:if_monitor` - Set to `MdnsLite.VintageNetMonitor` when using Nerves or
    `MdnsLite.InetMonitor` elsewhere.  The default is
    `MdnsLite.VintageNetMonitor`.
  * `:dns_bridge_enabled` - Set to `true` to start a DNS server running that
    will bridge DNS to mDNS.
  * `:dns_bridge_ip` - The IP address for the DNS server. Defaults to
    127.0.0.53.
  * `:dns_bridge_port` - The UDP port for the DNS server. Defaults to 53.
  * `:dns_bridge_recursive` - If a regular DNS request comes on the DNS bridge,
    forward it to a DNS server rather than returning an error. This is the
    default since there's an issue on Linux and Nerves that prevents Erlang's
    DNS resolver from checking the next one.
  * `:services` - A list of services to advertise. See `MdnsLite.service` for
    details.

  Some options are modifiable at runtime. Functions for modifying these are in
  the `MdnsLite` module.
  """

  require Logger

  @default_host_name_list [:hostname]
  @default_ttl 120
  @default_dns_ip {127, 0, 0, 53}
  @default_dns_port 53
  @default_excluded_ifnames ["lo0", "lo", "ppp0", "wwan0", "__unknown"]
  @default_ipv4_only true

  defstruct services: MapSet.new(),
            dot_local_names: [],
            hosts: [],
            ttl: @default_ttl,
            instance_name: :unspecified,
            dns_bridge_enabled: false,
            dns_bridge_ip: @default_dns_ip,
            dns_bridge_port: @default_dns_port,
            dns_bridge_recursive: false,
            if_monitor: nil,
            excluded_ifnames: @default_excluded_ifnames,
            ipv4_only: @default_ipv4_only

  @typedoc false
  @type t :: %__MODULE__{
          services: MapSet.t(map()),
          dot_local_names: [String.t()],
          hosts: [String.t()],
          ttl: pos_integer(),
          instance_name: MdnsLite.instance_name(),
          dns_bridge_enabled: boolean(),
          dns_bridge_ip: :inet.ip_address(),
          dns_bridge_port: 1..65535,
          dns_bridge_recursive: boolean(),
          if_monitor: module(),
          excluded_ifnames: [String.t()],
          ipv4_only: boolean()
        }

  @doc false
  @spec new(Enumerable.t()) :: t()
  def new(enumerable \\ %{}) do
    opts = Map.new(enumerable)

    hosts = get_host_option(opts)
    ttl = Map.get(opts, :ttl, @default_ttl)
    instance_name = Map.get(opts, :instance_name, :unspecified)
    config_services = Map.get(opts, :services, []) |> filter_invalid_services()
    dns_bridge_enabled = Map.get(opts, :dns_bridge_enabled, false)
    dns_bridge_ip = Map.get(opts, :dns_bridge_ip, @default_dns_ip)
    dns_bridge_port = Map.get(opts, :dns_bridge_port, @default_dns_port)
    dns_bridge_recursive = Map.get(opts, :dns_bridge_recursive, false)
    if_monitor = Map.get(opts, :if_monitor, default_if_monitor())
    ipv4_only = Map.get(opts, :ipv4_only, @default_ipv4_only)
    excluded_ifnames = Map.get(opts, :excluded_ifnames, @default_excluded_ifnames)

    %__MODULE__{
      ttl: ttl,
      instance_name: instance_name,
      dns_bridge_enabled: dns_bridge_enabled,
      dns_bridge_ip: dns_bridge_ip,
      dns_bridge_port: dns_bridge_port,
      dns_bridge_recursive: dns_bridge_recursive,
      if_monitor: if_monitor,
      excluded_ifnames: excluded_ifnames,
      ipv4_only: ipv4_only
    }
    |> add_hosts(hosts)
    |> add_services(config_services)
  end

  defp default_if_monitor() do
    if has_vintage_net?() do
      MdnsLite.VintageNetMonitor
    else
      MdnsLite.InetMonitor
    end
  end

  defp has_vintage_net?() do
    Application.loaded_applications()
    |> Enum.find_value(fn {app, _, _} -> app == :vintage_net end)
  end

  # This used to be called :host, but now it's :hosts. It's a list, but be
  # nice and wrap rather than crash.
  defp get_host_option(%{host: host}) do
    Logger.warning("mdns_lite: the :host app environment option is deprecated. Change to :hosts")
    List.wrap(host)
  end

  defp get_host_option(%{hosts: hosts}), do: List.wrap(hosts)
  defp get_host_option(_), do: @default_host_name_list

  @doc false
  @spec set_instance_name(t(), MdnsLite.instance_name()) :: t()
  def set_instance_name(options, instance_name) do
    %{options | instance_name: instance_name}
  end

  @doc false
  @spec add_service(t(), MdnsLite.service()) :: t()
  def add_service(options, service) do
    {:ok, normalized_service} = normalize_service(service)
    %{options | services: MapSet.put(options.services, normalized_service)}
  end

  @doc false
  @spec add_services(t(), [MdnsLite.service()]) :: t()
  def add_services(%__MODULE__{} = options, services) do
    Enum.reduce(services, options, fn service, options -> add_service(options, service) end)
  end

  @doc false
  @spec filter_invalid_services([MdnsLite.service()]) :: [MdnsLite.service()]
  def filter_invalid_services(services) do
    Enum.flat_map(services, fn service ->
      case normalize_service(service) do
        {:ok, normalized_service} ->
          [normalized_service]

        {:error, reason} ->
          Logger.warning("mdns_lite: ignoring service (#{inspect(service)}): #{reason}")
          []
      end
    end)
  end

  @doc """
  Normalize a service description

  All service descriptions are normalized before use. Call this function if
  you're unsure how the service description will be transformed for use.
  """
  @spec normalize_service(MdnsLite.service()) :: {:ok, MdnsLite.service()} | {:error, String.t()}
  def normalize_service(service) do
    with {:ok, id} <- normalize_id(service),
         {:ok, instance_name} <- normalize_instance_name(service),
         {:ok, port} <- normalize_port(service),
         {:ok, type} <- normalize_type(service) do
      {:ok,
       %{
         id: id,
         instance_name: instance_name,
         port: port,
         type: type,
         txt_payload: Map.get(service, :txt_payload, []),
         priority: Map.get(service, :priority, 0),
         weight: Map.get(service, :weight, 0)
       }}
    end
  end

  defp normalize_id(%{id: id}), do: {:ok, id}

  defp normalize_id(%{name: name}) do
    Logger.warning("mdns_lite: names are deprecated now. Specify an :id that's an atom")
    {:ok, name}
  end

  defp normalize_id(_), do: {:ok, :unspecified}

  defp normalize_instance_name(%{instance_name: instance_name}), do: {:ok, instance_name}
  defp normalize_instance_name(_), do: {:ok, :unspecified}

  defp normalize_type(%{type: type}) when is_binary(type) and byte_size(type) > 0 do
    {:ok, type}
  end

  defp normalize_type(%{protocol: protocol, transport: transport} = service)
       when is_binary(protocol) and is_binary(transport) do
    {:ok, "_#{service.protocol}._#{service.transport}"}
  end

  defp normalize_type(_other) do
    {:error, "Specify either 1. :protocol and :transport or 2. :type"}
  end

  defp normalize_port(%{port: port}) when port >= 0 and port <= 65535, do: {:ok, port}
  defp normalize_port(_), do: {:error, "Specify a port"}

  @doc false
  @spec get_services(t()) :: [MdnsLite.service()]
  def get_services(%__MODULE__{} = options) do
    MapSet.to_list(options.services)
  end

  @doc false
  @spec remove_service_by_id(t(), MdnsLite.service_id()) :: t()
  def remove_service_by_id(%__MODULE__{} = options, service_id) do
    services_set =
      options.services
      |> Enum.reject(&(&1.id == service_id))
      |> MapSet.new()

    %{options | services: services_set}
  end

  @doc false
  @spec set_hosts(t(), [String.t() | :hostname]) :: t()
  def set_hosts(%__MODULE__{} = options, hosts) do
    %{options | dot_local_names: [], hosts: []}
    |> add_hosts(hosts)
  end

  @doc false
  @spec add_host(t(), String.t() | :hostname) :: t()
  def add_host(%__MODULE__{} = options, host) do
    resolved_host = resolve_mdns_name(host)
    dot_local_name = "#{resolved_host}.local"

    %{
      options
      | dot_local_names: options.dot_local_names ++ [dot_local_name],
        hosts: options.hosts ++ [resolved_host]
    }
  end

  @doc false
  @spec add_hosts(t(), [String.t() | :hostname]) :: t()
  def add_hosts(%__MODULE__{} = options, hosts) do
    Enum.reduce(hosts, options, &add_host(&2, &1))
  end

  defp resolve_mdns_name(:hostname) do
    {:ok, hostname} = :inet.gethostname()
    to_string(hostname)
  end

  defp resolve_mdns_name(mdns_name) when is_binary(mdns_name), do: mdns_name

  defp resolve_mdns_name(_other) do
    raise RuntimeError, "Host must be :hostname or a string"
  end
end
