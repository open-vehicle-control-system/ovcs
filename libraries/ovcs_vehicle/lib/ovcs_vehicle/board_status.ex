defmodule OvcsVehicle.BoardStatus do
  @moduledoc """
  How to reach a board and whether its clock can be trusted, as each
  dashboard's top bar shows them: every network interface with a device
  that is up and running, with its addresses, IPv6 link-local ones left
  out, and the clock's UTC time with whether NTP synchronized it
  (`NervesTime.synchronized?/0`). A host, without NervesTime, reports no
  synchronization, `nil`.

  An interface without a device in `/sys/class/net`, such as loopback, a
  container bridge or a tunnel, is left out.

  Options, for tests: `:getifaddrs`, `:now` and `:synchronized?`,
  functions of no argument, and `:device?`, a function of an interface's
  name.
  """

  @enforce_keys [:interfaces, :time, :synchronized]
  defstruct @enforce_keys

  @type interface :: %{name: String.t(), addresses: [String.t()]}
  @type t :: %__MODULE__{
          interfaces: [interface()],
          time: DateTime.t(),
          synchronized: boolean() | nil
        }

  # Resolved at runtime, as in `OvcsVehicle.ClockSync`: the firmwares bring
  # NervesTime, a host has none.
  @nerves_time_parts [:NervesTime]

  @doc "The board's interfaces and clock now."
  @spec current(keyword()) :: t()
  def current(opts \\ []) do
    getifaddrs = Keyword.get(opts, :getifaddrs, &:inet.getifaddrs/0)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    synchronized? = Keyword.get(opts, :synchronized?, &synchronized?/0)
    device? = Keyword.get(opts, :device?, &File.exists?("/sys/class/net/#{&1}/device"))

    %__MODULE__{
      interfaces: interfaces(getifaddrs.(), device?),
      time: DateTime.truncate(now.(), :second),
      synchronized: synchronized?.()
    }
  end

  defp interfaces({:ok, ifaddrs}, device?) do
    for {name, options} <- ifaddrs,
        name = List.to_string(name),
        running?(Keyword.get(options, :flags, [])),
        device?.(name),
        addresses = for({:addr, address} <- options, reachable?(address), do: format(address)),
        addresses != [],
        do: %{name: name, addresses: addresses}
  end

  defp interfaces(_error, _device?), do: []

  defp running?(flags), do: :up in flags and :running in flags and :loopback not in flags

  # fe80::/10 only reaches the link, through an interface a browser cannot name.
  defp reachable?({first, _, _, _, _, _, _, _}), do: Bitwise.band(first, 0xFFC0) != 0xFE80
  defp reachable?(_ipv4), do: true

  defp format(address), do: address |> :inet.ntoa() |> List.to_string()

  defp synchronized? do
    nerves_time = Module.concat(@nerves_time_parts)

    if Code.ensure_loaded?(nerves_time) and function_exported?(nerves_time, :synchronized?, 0),
      do: nerves_time.synchronized?()
  end
end
