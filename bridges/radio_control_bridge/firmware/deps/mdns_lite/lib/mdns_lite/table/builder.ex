defmodule MdnsLite.Table.Builder do
  @moduledoc false

  import MdnsLite.DNS

  alias MdnsLite.Options

  @doc """
  Create a table based on the user options
  """
  @spec from_options(Options.t()) :: MdnsLite.Table.t()
  def from_options(%Options{} = config) do
    # TODO: This could be seriously simplified...
    []
    |> add_a_records(config)
    |> add_ptr_records(config)
    |> add_records_for_services(config)
    |> add_ptr_records3(config)
    |> Enum.uniq()
  end

  defp add_a_records(records, config) do
    records ++
      for dot_local_name <- config.dot_local_names do
        to_dns_rr(:in, :a, dot_local_name, config.ttl, :ipv4_address)
      end ++
      for dot_local_name <- config.dot_local_names do
        to_dns_rr(:in, :aaaa, dot_local_name, config.ttl, :ipv6_address)
      end
  end

  defp add_ptr_records(records, %Options{} = config) do
    # services._dns-sd._udp.local. is a special name for
    # "Service Type Enumeration" which is supposed to find all service
    # types on the network. Let them know about ours.
    domain = "_services._dns-sd._udp.local"

    resources =
      Options.get_services(config)
      |> Enum.map(fn service ->
        to_dns_rr(:in, :ptr, domain, config.ttl, to_charlist(service.type <> ".local"))
      end)

    records ++ resources
  end

  defp add_records_for_services(records, config) do
    Options.get_services(config)
    |> Enum.group_by(fn service -> service.type <> ".local" end)
    |> Enum.reduce(records, &records_for_service_type(&1, &2, config))
  end

  defp records_for_service_type({domain, services}, records, config) do
    value = Enum.flat_map(services, &service_resources(&1, domain, config))
    value ++ records
  end

  defp service_resources(service, domain, config) do
    service_instance_name =
      case service.instance_name do
        :unspecified ->
          case config.instance_name do
            :unspecified ->
              name = hd(config.hosts)
              to_charlist("#{name}.#{service.type}.local")

            host_instance_name ->
              to_charlist("#{host_instance_name}.#{service.type}.local")
          end

        service_instance_name ->
          to_charlist("#{service_instance_name}.#{service.type}.local")
      end

    first_dot_local_name = hd(config.dot_local_names)
    target = first_dot_local_name <> "."
    srv_data = {service.priority, service.weight, service.port, to_charlist(target)}

    [
      to_dns_rr(:in, :ptr, domain, config.ttl, service_instance_name),
      to_dns_rr(
        :in,
        :txt,
        service_instance_name,
        config.ttl,
        to_charlist(service.txt_payload)
      ),
      to_dns_rr(:in, :srv, service_instance_name, config.ttl, srv_data),
      to_dns_rr(:in, :a, first_dot_local_name, config.ttl, :ipv4_address)
    ]
  end

  defp add_ptr_records3(records, %Options{} = config) do
    first_dot_local_name = hd(config.dot_local_names) |> to_charlist()

    [
      to_dns_rr(:in, :ptr, :ipv4_arpa_address, config.ttl, first_dot_local_name),
      to_dns_rr(:in, :ptr, :ipv6_arpa_address, config.ttl, first_dot_local_name) | records
    ]
  end

  defp to_dns_rr(class, type, domain, ttl, data) do
    dns_rr(
      domain: normalize_domain(domain),
      class: class,
      type: type,
      ttl: ttl,
      data: data
    )
  end

  defp normalize_domain(d) when is_atom(d), do: d
  defp normalize_domain(d), do: to_charlist(d)
end
