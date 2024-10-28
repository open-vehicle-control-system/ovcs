defmodule OneDHCPD.ARP do
  @moduledoc """
  This module contains utilities to view or update the ARP cache.

  OneDHCPD uses this to update the ARP cache when the IP address is given
  out. If networking isn't working, `OneDHCPD.ARP.entries/0` is useful
  for debugging.
  """

  defmodule Entry do
    @moduledoc """
    One entry in the ARP table
    """
    defstruct ip: nil,
              ifname: nil,
              hwaddr: nil,
              state: nil

    @type t :: %__MODULE__{
            ip: :inet.ip_address(),
            ifname: String.t(),
            hwaddr: [byte()],
            state: String.t()
          }
  end

  @doc """
  Query the ARP cache and return everything in it.

  Currently this function is only used for debug.
  """
  @spec entries() :: [Entry.t()]
  def entries() do
    {output, 0} = System.cmd("ip", ["neigh", "show"])

    output
    |> String.split("\n")
    |> Enum.map(&line_to_entry/1)
    |> Enum.filter(&is_map/1)
  end

  @doc """
  Replace an entry in the ARP cache.
  """
  @spec replace(String.t(), :inet.ip_address(), [byte()]) :: :ok | {:error, any()}
  def replace(ifname, ip, hwaddr) do
    ip_str = :inet.ntoa(ip) |> to_string()
    hwaddr_str = format_hw_address(hwaddr)

    # This could be done by running:
    #
    # ip neigh replace dev <ifname> to <ip_str> lladdr <hwaddr_str> nud reachable
    # or calling arp -s
    #
    # Unfortunately Nerves doesn't support either since Busybox's ip doesn't
    # support replace and arp isn't enabled. So... we made a little port to
    # call the ioctl.

    arp_set = Application.app_dir(:one_dhcpd, "priv/arp_set")

    case System.cmd(arp_set, [
           ifname,
           ip_str,
           hwaddr_str
         ]) do
      {_output, 0} -> :ok
      {output, _rc} -> {:error, output}
    end
  end

  defp line_to_entry(line) do
    line
    |> String.split(" ")
    |> make_entry()
  end

  # iproute2 format
  defp make_entry([ip, "dev", ifname, "lladdr", hwaddr, state]) do
    {:ok, ip_address} = parse_ip_address(ip)

    %Entry{
      ip: ip_address,
      ifname: ifname,
      hwaddr: parse_hw_address(hwaddr),
      state: state
    }
  end

  # iproute2 format
  defp make_entry([ip, "dev", ifname, "lladdr", hwaddr, "router", state]) do
    {:ok, ip_address} = parse_ip_address(ip)

    %Entry{
      ip: ip_address,
      ifname: ifname,
      hwaddr: parse_hw_address(hwaddr),
      state: state
    }
  end

  # Busybox ip-neigh
  defp make_entry([
         ip,
         "dev",
         ifname,
         "lladdr",
         hwaddr | rest
       ]) do
    {:ok, ip_address} = parse_ip_address(ip)
    state = List.last(rest)

    %Entry{
      ip: ip_address,
      ifname: ifname,
      hwaddr: parse_hw_address(hwaddr),
      state: state
    }
  end

  defp make_entry(_other), do: nil

  defp parse_ip_address(s) do
    :inet.parse_address(to_charlist(s))
  end

  defp parse_hw_address(
         <<a::2-bytes, ":", b::2-bytes, ":", c::2-bytes, ":", d::2-bytes, ":", e::2-bytes, ":",
           f::2-bytes>>
       ) do
    [
      String.to_integer(a, 16),
      String.to_integer(b, 16),
      String.to_integer(c, 16),
      String.to_integer(d, 16),
      String.to_integer(e, 16),
      String.to_integer(f, 16)
    ]
  end

  defp format_hw_address(addr) when is_list(addr) and length(addr) == 6 do
    :io_lib.format(~c"~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B:~2.16.0B", addr)
    |> to_string()
  end
end
