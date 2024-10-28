defmodule MdnsLite.CoreMonitor do
  @moduledoc """
  Core logic for network monitors

  This module contains most of the logic needed for writing a network monitor.
  It's only intended to be called from `MdnsLite.InetMonitor` and
  `MdnsLite.VintageNetMonitor`.
  """

  @typedoc """
  Monitor options

  * `:excluded_ifnames` - a list of network interface names to ignore
  * `:ipv4_only` - set to `true` to ignore all IPv6 addresses
  """
  @type option() ::
          {:excluded_ifnames, [String.t()]}
          | {:ipv4_only, boolean()}

  @typedoc false
  @type state() :: %{
          excluded_ifnames: [String.t()],
          ip_list: %{String.t() => [:inet.ip_address()]},
          filter: ([:inet.ip_address()] -> [:inet.ip_address()]),
          todo: [mfa()]
        }

  @spec init([option()]) :: state()
  def init(opts) do
    excluded_ifnames = Keyword.get(opts, :excluded_ifnames, [])
    filter = if Keyword.get(opts, :ipv4_only, true), do: &filter_by_ipv4/1, else: &no_filter/1

    %{
      excluded_ifnames: excluded_ifnames,
      ip_list: %{},
      filter: filter,
      todo: []
    }
  end

  @spec set_ip_list(state(), String.t(), [:inet.ip_address()]) :: state()
  def set_ip_list(%{} = state, ifname, ip_list) do
    if ifname in state.excluded_ifnames do
      # Ignore excluded interface
      state
    else
      current_list = Map.get(state.ip_list, ifname, [])
      new_list = state.filter.(ip_list)

      {to_remove, to_add} = compute_delta(current_list, new_list)

      new_todo =
        state.todo ++
          Enum.map(to_remove, &{MdnsLite.ResponderSupervisor, :stop_child, [ifname, &1]}) ++
          Enum.map(to_add, &{MdnsLite.ResponderSupervisor, :start_child, [ifname, &1]})

      %{state | todo: new_todo, ip_list: Map.put(state.ip_list, ifname, new_list)}
    end
  end

  @spec flush_todo_list(state()) :: state()
  def flush_todo_list(state) do
    Enum.each(state.todo, fn {m, f, a} -> apply(m, f, a) end)

    %{state | todo: []}
  end

  @spec unset_remaining_ifnames(state(), [String.t()]) :: state()
  def unset_remaining_ifnames(state, new_ifnames) do
    Enum.reduce(known_ifnames(state), state, fn ifname, state ->
      if ifname in new_ifnames do
        state
      else
        set_ip_list(state, ifname, [])
      end
    end)
  end

  defp known_ifnames(state) do
    Map.keys(state.ip_list)
  end

  defp compute_delta(old_list, new_list) do
    {old_list -- new_list, new_list -- old_list}
  end

  defp no_filter(ip_list) do
    ip_list
  end

  defp filter_by_ipv4(ip_list) do
    Enum.filter(ip_list, &(MdnsLite.Utilities.ip_family(&1) == :inet))
  end
end
