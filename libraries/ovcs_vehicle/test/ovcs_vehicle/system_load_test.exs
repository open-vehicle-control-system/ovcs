defmodule OvcsVehicle.SystemLoadTest do
  use ExUnit.Case, async: true

  alias OvcsVehicle.SystemLoad

  @earlier_stat "cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 25 0 12 200 12 0 0 0 0 0\n"
  @later_stat "cpu  160 0 90 840 60 0 0 0 0 0\ncpu0 40 0 22 210 15 0 0 0 0 0\n"

  test "the CPU busy share between two /proc/stat readings" do
    earlier = SystemLoad.parse_cpu(@earlier_stat)
    later = SystemLoad.parse_cpu(@later_stat)

    # 100 busy of 150 ticks, idle and iowait not counted as busy.
    assert SystemLoad.cpu_percent(earlier, later) == 100 * 100 / 150
  end

  test "no reading gives no share" do
    assert SystemLoad.parse_cpu("nothing") == nil
    assert SystemLoad.cpu_percent(nil, SystemLoad.parse_cpu(@earlier_stat)) == nil
  end

  test "reads this machine's CPU times" do
    assert {busy, total} = SystemLoad.cpu_times()
    assert busy <= total
  end

  test "the share of the memory in use, from /proc/meminfo: what is not available" do
    meminfo =
      "MemTotal:        8000000 kB\nMemFree:          500000 kB\nMemAvailable:    6000000 kB\n"

    assert SystemLoad.parse_meminfo(meminfo) == 25.0
    assert SystemLoad.parse_meminfo("MemTotal: 8000000 kB\n") == nil
    assert SystemLoad.parse_meminfo("") == nil
  end

  test "the 1, 5 and 15 minute load averages of /proc/loadavg" do
    assert SystemLoad.parse_loadavg("0.52 0.48 0.40 1/123 4567\n") == [0.52, 0.48, 0.4]
    assert SystemLoad.parse_loadavg("") == nil
  end
end
