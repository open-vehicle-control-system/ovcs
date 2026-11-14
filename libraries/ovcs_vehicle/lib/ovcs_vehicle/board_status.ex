defmodule OvcsVehicle.BoardStatus do
  @moduledoc """
  How to reach a board and whether its clock can be trusted, as each
  dashboard's top bar shows them: every network interface with a device
  that is up and running, with its addresses, IPv6 link-local ones left
  out, its load, the CPU's busy share over a half-second sample and the 1,
  5 and 15 minute load averages and the share of its memory in use
  (`OvcsVehicle.SystemLoad`), and the
  clock's UTC time with whether NTP synchronized it
  (`NervesTime.synchronized?/0`). A host, without NervesTime, reports no
  synchronization, `nil`.

  An interface without a device in `/sys/class/net`, such as loopback, a
  container bridge or a tunnel, is left out.

  `document/1` is the one JSON document every API serves at `GET /api/board`.

  Options, for tests: `:getifaddrs`, `:cpu_times`, `:loadavg`, `:meminfo`, `:now` and
  `:synchronized?`, functions of no argument, `:device?`, a function of an
  interface's name, and `:sleep`, of the sample's milliseconds.
  """

  alias OvcsVehicle.SystemLoad

  @enforce_keys [:interfaces, :cpu_percent, :load_average, :memory_percent, :time, :synchronized]
  defstruct @enforce_keys

  @type interface :: %{name: String.t(), addresses: [String.t()]}
  @type t :: %__MODULE__{
          interfaces: [interface()],
          cpu_percent: float() | nil,
          load_average: [float()] | nil,
          memory_percent: float() | nil,
          time: DateTime.t(),
          synchronized: boolean() | nil
        }

  # Resolved at runtime, as in `OvcsVehicle.ClockSync`: the firmwares bring
  # NervesTime, a host has none.
  @nerves_time_parts [:NervesTime]

  @cpu_sample_ms 500

  @doc "The board's interfaces and clock now."
  @spec current(keyword()) :: t()
  def current(opts \\ []) do
    getifaddrs = Keyword.get(opts, :getifaddrs, &:inet.getifaddrs/0)
    now = Keyword.get(opts, :now, &DateTime.utc_now/0)
    synchronized? = Keyword.get(opts, :synchronized?, &synchronized?/0)
    device? = Keyword.get(opts, :device?, &File.exists?("/sys/class/net/#{&1}/device"))
    cpu_times = Keyword.get(opts, :cpu_times, &SystemLoad.cpu_times/0)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    loadavg = Keyword.get(opts, :loadavg, fn -> read("/proc/loadavg") end)
    meminfo = Keyword.get(opts, :meminfo, fn -> read("/proc/meminfo") end)

    %__MODULE__{
      interfaces: interfaces(getifaddrs.(), device?),
      cpu_percent: cpu_percent(cpu_times, sleep),
      load_average: load_average(loadavg.()),
      memory_percent: memory_percent(meminfo.()),
      time: DateTime.truncate(now.(), :second),
      synchronized: synchronized?.()
    }
  end

  @doc """
  The board as the JSON:API document every API answers to `GET /api/board`:
  the `boards` resource `current`, with `interfaces`, `cpuPercent`,
  `loadAverage`, `memoryPercent`, `time` in ISO 8601 UTC and
  `clockSynchronized`, `nil` where the board does not report them.
  """
  @spec document(t()) :: map()
  def document(%__MODULE__{} = board) do
    %{
      data: %{
        type: "boards",
        id: "current",
        attributes: %{
          interfaces: board.interfaces,
          cpuPercent: board.cpu_percent,
          loadAverage: board.load_average,
          memoryPercent: board.memory_percent,
          time: board.time |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601(),
          clockSynchronized: board.synchronized
        }
      }
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

  defp cpu_percent(cpu_times, sleep) do
    earlier = cpu_times.()
    sleep.(@cpu_sample_ms)

    case SystemLoad.cpu_percent(earlier, cpu_times.()) do
      nil -> nil
      percent -> Float.round(percent, 1)
    end
  end

  defp load_average(nil), do: nil
  defp load_average(loadavg), do: SystemLoad.parse_loadavg(loadavg)

  defp memory_percent(nil), do: nil

  defp memory_percent(meminfo) do
    case SystemLoad.parse_meminfo(meminfo) do
      nil -> nil
      percent -> Float.round(percent, 1)
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, _reason} -> nil
    end
  end

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
