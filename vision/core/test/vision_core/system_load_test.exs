defmodule VisionCore.SystemLoadTest do
  use ExUnit.Case, async: true

  alias VisionCore.SystemLoad

  @stat_a "cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 25 0 12 200 12 0 0 0 0 0\n"
  @stat_b "cpu  160 0 90 840 60 0 0 0 0 0\ncpu0 40 0 22 210 15 0 0 0 0 0\n"

  test "the CPU busy share between two /proc/stat readings" do
    a = SystemLoad.parse_cpu(@stat_a)
    b = SystemLoad.parse_cpu(@stat_b)

    # 100 busy of 150 ticks, idle and iowait not counted as busy.
    assert SystemLoad.cpu_percent(a, b) == 100 * 100 / 150
  end

  test "no reading gives no share" do
    assert SystemLoad.parse_cpu("nothing") == nil
    assert SystemLoad.cpu_percent(nil, SystemLoad.parse_cpu(@stat_a)) == nil
  end

  test "reads this machine's CPU times" do
    assert {busy, total} = SystemLoad.cpu_times()
    assert busy <= total
  end
end
