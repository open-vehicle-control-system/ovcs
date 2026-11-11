defmodule OvcsVehicle.ClockSyncTest do
  use ExUnit.Case, async: true

  alias OvcsVehicle.ClockSync

  defp options(test_pid, connected?, synchronized?, extra \\ []) do
    [
      connected?: fn -> connected? end,
      synchronized?: fn -> synchronized? end,
      restart: fn -> send(test_pid, :restarted) end,
      subscribe: fn -> send(test_pid, :subscribed) end,
      interval_ms: 60_000
    ]
    |> Keyword.merge(extra)
  end

  describe "check/1" do
    test "restarts ntpd when the network is up and the clock is not synchronized" do
      assert ClockSync.check(options(self(), true, false)) == :restarted
      assert_received :restarted
    end

    test "leaves ntpd alone once the clock is synchronized" do
      assert ClockSync.check(options(self(), true, true)) == :ok
      refute_received :restarted
    end

    test "leaves ntpd alone while the network is down" do
      assert ClockSync.check(options(self(), false, false)) == :ok
      refute_received :restarted
    end
  end

  describe "the process" do
    test "subscribes to the connection and checks when it becomes :internet" do
      pid = start_supervised!({ClockSync, options(self(), true, false)})
      assert_receive :subscribed

      send(pid, {VintageNet, ["connection"], :lan, :internet, %{}})
      assert_receive :restarted
    end

    test "does not check on other connection changes" do
      pid = start_supervised!({ClockSync, options(self(), true, false)})
      assert_receive :subscribed

      send(pid, {VintageNet, ["connection"], :internet, :lan, %{}})
      refute_receive :restarted, 50
    end

    test "checks again every interval" do
      start_supervised!({ClockSync, options(self(), true, false, interval_ms: 20)})

      assert_receive :restarted
      assert_receive :restarted
    end
  end
end
