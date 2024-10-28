defmodule MdnsLite.Info do
  @moduledoc """
  Inspect internal MdnsLite state

  Functions in this module are intended for debugging mDNS issues.
  """

  alias MdnsLite.{Responder, TableServer}

  @doc """
  Dump the records that mDNSLite advertises
  """
  @spec dump_records() :: :ok
  def dump_records() do
    TableServer.get_records()
    |> format_rr([], "\n")
    |> IO.puts()
  end

  @doc """
  Dump the contents of the responder mDNS caches
  """
  @spec dump_caches() :: :ok
  def dump_caches() do
    Responder.get_all_caches()
    |> Enum.map(fn %{ifname: ifname, ip: ip, cache: cache} ->
      [
        "Responder (",
        :inet.ntoa(ip),
        "%",
        ifname,
        "):\n",
        format_rr(cache.records, "  ", "\n")
      ]
    end)
    |> IO.puts()
  end

  defp format_rr(rr, prefix, postfix) do
    rr
    |> Enum.sort()
    |> Enum.map(fn rec -> [prefix, MdnsLite.DNS.pretty(rec), postfix] end)
  end
end
