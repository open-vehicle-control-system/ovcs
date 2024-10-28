defmodule MdnsLite.Table do
  @moduledoc false
  import MdnsLite.DNS
  alias MdnsLite.{DNS, IfInfo}

  @type t() :: [DNS.dns_rr()]

  # TODO: make this more consistent
  @type tmp_results() :: %{additional: [DNS.dns_rr()], answer: [DNS.dns_rr()]}

  # RFC6762 Section 6: Responding
  #
  # The determination of whether a given record answers a given question
  # is made using the standard DNS rules: the record name must match the
  # question name, the record rrtype must match the question qtype unless
  # the qtype is "ANY" (255) or the rrtype is "CNAME" (5), and the record
  # rrclass must match the question qclass unless the qclass is "ANY"
  # (255).
  @spec query(t(), DNS.dns_query(), IfInfo.t()) :: [DNS.dns_rr()]
  def query(table, query, %IfInfo{} = if_info) do
    query
    |> normalize_query(if_info)
    |> run_query(table)
    |> Enum.flat_map(&fixup_rr(&1, if_info))
  end

  @doc """
  Add additional records per RFC 6763 Section 12

  Note: The following text in the RFC indicates that this is optional,
  but it really seems based on PRs/issues that it is not.

  >>>
   Clients MUST be capable of functioning correctly with DNS servers
   (and Multicast DNS Responders) that fail to generate these additional
   records automatically, by issuing subsequent queries for any further
   record(s) they require.  The additional-record generation rules in
   this section are RECOMMENDED for improving network efficiency, but
   are not required for correctness.
  >>>
  """
  @spec additional_records(t(), [DNS.dns_rr()], IfInfo.t()) :: [DNS.dns_rr()]
  def additional_records(table, rr, %IfInfo{} = if_info) do
    rr
    |> Enum.reduce([], &add_additional_records(&1, &2, table, if_info))
    |> Enum.uniq()
  end

  @spec merge_results(tmp_results(), tmp_results()) :: tmp_results()
  def merge_results(%{answer: answer1, additional: add1}, %{answer: answer2, additional: add2}) do
    # TODO: compare uniqueness based on the domain, type, class, and data only.
    %{answer: Enum.uniq(answer1 ++ answer2), additional: Enum.uniq(add1 ++ add2)}
  end

  # RFC 6763 12.3 No additional records for text records
  defp add_additional_records(dns_rr(type: :text), acc, _table, _if_info) do
    acc
  end

  # RFC 6763 12.2 All address records (type "A" and "AAAA") named in the SRV rdata
  defp add_additional_records(
         dns_rr(type: :srv, data: {_priority, _weight, _port, domain}),
         acc,
         table,
         if_info
       ) do
    # Remove the trailing dot at the end of the domain
    hostname = List.delete_at(domain, -1)

    acc ++
      query(table, dns_query(class: :in, type: :a, domain: hostname), if_info) ++
      query(table, dns_query(class: :in, type: :aaaa, domain: hostname), if_info)
  end

  # RFC 6763 12.1
  #  The SRV record(s) named in the PTR rdata.
  #  The TXT record(s) named in the PTR rdata.
  #  All address records (type "A" and "AAAA") named in the SRV rdata.
  defp add_additional_records(
         dns_rr(type: :ptr, data: domain),
         acc,
         table,
         if_info
       ) do
    srv_records = query(table, dns_query(class: :in, type: :srv, domain: domain), if_info)
    txt_records = query(table, dns_query(class: :in, type: :txt, domain: domain), if_info)
    a_records = additional_records(table, srv_records, if_info)

    acc ++ srv_records ++ txt_records ++ a_records
  end

  # RFC 6763 12.4 No additional records for other types
  defp add_additional_records(_record, acc, _table, _if_info) do
    acc
  end

  defp run_query(dns_query(class: class, type: type, domain: domain), table) do
    Enum.filter(table, fn dns_rr(class: c, type: t, domain: d) ->
      c == class and t == type and d == domain
    end)
  end

  defp normalize_query(dns_query(class: :in, type: :ptr, domain: domain) = q, if_info) do
    case test_known_in_addr_arpa(domain, if_info) do
      {:ok, value} -> dns_query(q, domain: value)
      _ -> q
    end
  end

  defp normalize_query(query, _if_info) do
    query
  end

  # TODO: Fate sharing - send IPv6 records when sending IPv4 ones and vice versa
  defp fixup_rr(dns_rr(class: :in, type: :a, data: :ipv4_address) = rr, if_info) do
    [dns_rr(rr, data: if_info.ipv4_address)]
  end

  defp fixup_rr(dns_rr(class: :in, type: :aaaa, data: :ipv6_address) = rr, if_info) do
    for address <- if_info.ipv6_addresses do
      dns_rr(rr, data: address)
    end
  end

  defp fixup_rr(dns_rr(class: :in, type: :ptr, domain: :ipv4_arpa_address) = rr, if_info) do
    [dns_rr(rr, domain: ipv4_arpa_address(if_info))]
  end

  defp fixup_rr(rr, _if_info) do
    [rr]
  end

  defp parse_in_addr_arpa(name) do
    parts = name |> to_string() |> String.split(".") |> Enum.reverse()

    case parts do
      ["", "arpa", "in-addr" | ip_parts] ->
        ip_parts |> Enum.join(".") |> to_charlist() |> :inet.parse_ipv4_address()

      ["", "arpa", "ip6" | _ip_parts] ->
        # See https://datatracker.ietf.org/doc/html/rfc2874
        # E.g., 1.8.1.3.3.5.3.A.D.F.3.1.5.6.C.0.7.E.3.0.8.0.0.0.0.7.4.0.1.0.0.2.ip6.arpa
        {:error, :implement_ipv6}

      _ ->
        {:error, :not_in_addr_arpa}
    end
  end

  defp normalize_ip_address(address, %{ipv4_address: address}) do
    {:ok, :ipv4_arpa_address}
  end

  defp normalize_ip_address(address, %{ipv6_addresses: list}) do
    if address in list do
      {:ok, :ipv6_arpa_address}
    else
      {:error, :unknown_address}
    end
  end

  defp test_known_in_addr_arpa(name, if_info) do
    with {:ok, address} <- parse_in_addr_arpa(name) do
      normalize_ip_address(address, if_info)
    end
  end

  defp ipv4_arpa_address(if_info) do
    # Example ARPA address for IP 192.168.0.112 is 112.0.168.192.in-addr.arpa
    arpa_address =
      if_info.ipv4_address
      |> Tuple.to_list()
      |> Enum.reverse()
      |> Enum.join(".")

    to_charlist(arpa_address <> ".in-addr.arpa.")
  end
end
