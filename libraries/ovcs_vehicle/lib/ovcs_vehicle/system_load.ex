defmodule OvcsVehicle.SystemLoad do
  @moduledoc """
  A board's load, from Linux: the CPU's busy share, from `/proc/stat`, and
  the load averages, from `/proc/loadavg`, and the share of the memory in
  use, from `/proc/meminfo`.
  """

  @doc """
  The CPU's `{busy, total}` time in clock ticks since boot, over all cores,
  or `nil` where `/proc/stat` cannot be read.
  """
  @spec cpu_times() :: {non_neg_integer(), non_neg_integer()} | nil
  def cpu_times do
    case File.read("/proc/stat") do
      {:ok, stat} -> parse_cpu(stat)
      {:error, _reason} -> nil
    end
  end

  @doc "The `{busy, total}` of the aggregate `cpu` line of `/proc/stat`; idle and iowait are not busy."
  @spec parse_cpu(String.t()) :: {non_neg_integer(), non_neg_integer()} | nil
  def parse_cpu("cpu " <> rest) do
    [line | _] = String.split(rest, "\n", parts: 2)
    times = line |> String.split() |> Enum.map(&String.to_integer/1)
    [_user, _nice, _system, idle, iowait | _] = times
    total = Enum.sum(times)
    {total - idle - iowait, total}
  end

  def parse_cpu(_stat), do: nil

  @doc "The busy percentage between two `cpu_times/0` readings."
  @spec cpu_percent(tuple() | nil, tuple() | nil) :: float() | nil
  def cpu_percent({earlier_busy, earlier_total}, {later_busy, later_total})
      when later_total > earlier_total,
      do: 100 * (later_busy - earlier_busy) / (later_total - earlier_total)

  def cpu_percent(_earlier, _later), do: nil

  @doc """
  The percentage of the memory in use, what `MemAvailable` leaves of
  `MemTotal` in a `/proc/meminfo`, or `nil` without both.
  """
  @spec parse_meminfo(String.t()) :: float() | nil
  def parse_meminfo(meminfo) do
    with total when is_integer(total) and total > 0 <- kilobytes(meminfo, "MemTotal"),
         available when is_integer(available) <- kilobytes(meminfo, "MemAvailable") do
      100 * (total - available) / total
    else
      _missing -> nil
    end
  end

  defp kilobytes(meminfo, field) do
    case Regex.run(~r/^#{field}:\s+(\d+) kB$/m, meminfo) do
      [_line, kilobytes] -> String.to_integer(kilobytes)
      nil -> nil
    end
  end

  @doc "The three load averages leading a `/proc/loadavg` line."
  @spec parse_loadavg(String.t()) :: [float()] | nil
  def parse_loadavg(loadavg) do
    case String.split(loadavg) do
      [one, five, fifteen | _rest] -> Enum.map([one, five, fifteen], &String.to_float/1)
      _other -> nil
    end
  end
end
