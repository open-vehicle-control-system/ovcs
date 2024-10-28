defmodule MdnsLite.DNSBridge do
  @moduledoc """
  DNS server that responds to mDNS queries

  This is a simple DNS server that can be used to resolve mDNS queries
  so that the rest of Erlang and Elixir can seamlessly use mDNS. To use
  this, you must enable the `:dns_bridge_enabled` option and then make the
  first DNS server be this server's IP address and port.

  This DNS server can either return an error or recursively look up a non-mDNS record
  depending on how it's configured. Erlang's DNS resolver currently has an issue
  with the error strategy so it can't be used.

  Configure this using the following application environment options:

  * `:dns_bridge_enabled` - set to true to enable the bridge
  * `:dns_bridge_ip` - IP address in tuple form for server (defaults to `{127, 0, 0, 53}`)
  * `:dns_bridge_port` - UDP port for server (defaults to 53)
  * `:dns_bridge_recursive` - set to true to recursively look up non-mDNS queries
  """

  use GenServer

  import MdnsLite.DNS
  alias MdnsLite.{DNS, Options}
  require Logger

  @doc false
  @spec start_link(MdnsLite.Options.t()) :: GenServer.on_start()
  def start_link(%Options{} = init_args) do
    GenServer.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  ##############################################################################
  #   GenServer callbacks
  ##############################################################################
  @impl GenServer
  def init(opts) do
    if opts.dns_bridge_enabled do
      {:ok, udp} = :gen_udp.open(opts.dns_bridge_port, udp_options(opts))

      {:ok,
       %{
         udp: udp,
         recursive: opts.dns_bridge_recursive,
         our_ip_port: {opts.dns_bridge_ip, opts.dns_bridge_port}
       }}
    else
      :ignore
    end
  end

  @impl GenServer
  def handle_info({:udp, _socket, src_ip, src_port, packet}, state) do
    # Decode the UDP packet
    with {:ok, dns_record} <- DNS.decode(packet),
         dns_rec(header: header, qdlist: qdlist) = dns_record,
         # qr is the query/response flag; false (0) = query, true (1) = response
         dns_header(qr: false) <- header do
      # only respond to the first query

      result = MdnsLite.query(hd(qdlist))

      send_response(qdlist, result, dns_record, {src_ip, src_port}, state)
    else
      _ ->
        # Silently drop any unexpected packets
        :ok
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ##############################################################################
  #   Private functions
  ##############################################################################
  defp send_response(
         qdlist,
         %{answer: []},
         dns_rec(header: dns_header(id: id)),
         {dest_address, dest_port},
         state
       ) do
    result =
      if state.recursive do
        try_recursive_lookup(id, qdlist, state.our_ip_port)
      else
        lookup_failure(id, qdlist)
      end

    packet = DNS.encode(result)
    _ = :gen_udp.send(state.udp, dest_address, dest_port, packet)

    :ok
  end

  defp send_response(
         qdlist,
         result,
         dns_rec(header: dns_header(id: id, opcode: opcode, rd: rd)),
         {dest_address, dest_port},
         state
       ) do
    packet =
      dns_rec(
        header: dns_header(id: id, qr: true, opcode: opcode, aa: true, rd: rd, rcode: 0),
        # Query list. Must be empty according to RFC 6762 Section 6.
        qdlist: qdlist,
        # A list of answer entries. Can be empty.
        anlist: result.answer,
        # nslist Can be empty.
        nslist: [],
        # arlist A list of resource entries. Can be empty.
        arlist: result.additional
      )

    dns_record = DNS.encode(packet)
    # Best effort send
    _ = :gen_udp.send(state.udp, dest_address, dest_port, dns_record)
    :ok
  end

  defp udp_options(opts) do
    [
      :binary,
      active: true,
      ip: opts.dns_bridge_ip,
      reuseaddr: true
    ]
  end

  defp try_recursive_lookup(id, qdlist, our_ip_port) do
    dns_query(domain: domain, class: class, type: type) = hd(qdlist)

    case :inet_res.resolve(domain, class, type, nameservers: nameservers(our_ip_port)) do
      {:ok, result} ->
        header = dns_rec(result, :header)

        dns_rec(result, header: dns_header(header, id: id))

      {:error, _reason} ->
        lookup_failure(id, qdlist)
    end
  end

  defp nameservers(our_ip_port) do
    :inet_db.res_option(:nameservers)
    |> List.delete(our_ip_port)
  end

  defp lookup_failure(id, qdlist) do
    dns_rec(
      header: dns_header(id: id, qr: 1, aa: 0, tc: 0, rd: true, ra: 0, pr: 0, rcode: 5),
      qdlist: qdlist
    )
  end
end
