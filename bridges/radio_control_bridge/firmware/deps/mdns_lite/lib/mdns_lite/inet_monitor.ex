defmodule MdnsLite.InetMonitor do
  @moduledoc """
  Network monitor that uses Erlang's :inet functions

  Use this network monitor to detect new network interfaces and their
  IP addresses when not using Nerves. It regularly polls the system
  for changes so it's not as fast at starting mDNS responders as
  the `MdnsLite.VintageNetMonitor` is. However, it works everywhere.

  See `MdnsLite.Options` for how to set your `config.exs` to use it.
  """

  use GenServer

  alias MdnsLite.CoreMonitor
  require Logger

  @scan_interval 10000

  # Watch :inet.getifaddrs/0 for IP address changes and update the active responders.

  @doc false
  @spec start_link([CoreMonitor.option()]) :: GenServer.on_start()
  def start_link(init_args) do
    GenServer.start_link(__MODULE__, init_args, name: __MODULE__)
  end

  @impl GenServer
  def init(args) do
    {:ok, CoreMonitor.init(args), 1}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    {:noreply, update(state), @scan_interval}
  end

  defp update(state) do
    ifname_addresses = get_all_ip_addrs()
    ifnames = only_ifnames(ifname_addresses)

    ifname_addresses
    |> Enum.reduce(state, fn {ifname, ip_list}, state ->
      CoreMonitor.set_ip_list(state, ifname, ip_list)
    end)
    |> CoreMonitor.unset_remaining_ifnames(ifnames)
    |> CoreMonitor.flush_todo_list()
  end

  defp get_all_ip_addrs() do
    case :inet.getifaddrs() do
      {:ok, ifaddrs} ->
        Enum.map(ifaddrs, &ifaddr_to_ip_list/1)

      _error ->
        []
    end
  end

  defp ifaddr_to_ip_list({ifname, info}) do
    addrs = for addr <- Keyword.get_values(info, :addr), do: addr
    {to_string(ifname), addrs}
  end

  defp only_ifnames(ifname_addresses) do
    Enum.map(ifname_addresses, &elem(&1, 0)) |> Enum.uniq()
  end
end
