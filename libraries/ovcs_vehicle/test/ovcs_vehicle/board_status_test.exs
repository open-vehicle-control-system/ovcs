defmodule OvcsVehicle.BoardStatusTest do
  use ExUnit.Case, async: true

  alias OvcsVehicle.BoardStatus

  @now ~U[2026-11-11 14:53:12.345678Z]

  defp current(ifaddrs, synchronized \\ fn -> true end) do
    BoardStatus.current(
      getifaddrs: fn -> {:ok, ifaddrs} end,
      device?: &(&1 != "docker0"),
      now: fn -> @now end,
      synchronized?: synchronized
    )
  end

  defp up(addrs), do: [flags: [:up, :broadcast, :running, :multicast]] ++ addrs

  test "lists each running interface with its addresses, loopback and link-local left out" do
    status =
      current([
        {~c"lo",
         [flags: [:up, :loopback, :running], addr: {127, 0, 0, 1}, addr: {0, 0, 0, 0, 0, 0, 0, 1}]},
        {~c"eth0",
         up(
           addr: {192, 168, 10, 232},
           netmask: {255, 255, 255, 0},
           addr: {65_152, 0, 0, 0, 1, 2, 3, 4},
           addr: {8193, 3512, 0, 0, 0, 0, 0, 7}
         )},
        {~c"wlan0", up(addr: {172, 16, 0, 159})}
      ])

    assert status.interfaces == [
             %{name: "eth0", addresses: ["192.168.10.232", "2001:db8::7"]},
             %{name: "wlan0", addresses: ["172.16.0.159"]}
           ]
  end

  test "leaves out an interface that is down, not running, or without an address" do
    status =
      current([
        {~c"can0", [flags: [:up, :running]]},
        {~c"br-1", [flags: [:up, :broadcast, :multicast], addr: {172, 21, 0, 1}]},
        {~c"usb0", [flags: [:broadcast], addr: {172, 31, 1, 2}]},
        {~c"eth0", up(addr: {192, 168, 10, 232})}
      ])

    assert Enum.map(status.interfaces, & &1.name) == ["eth0"]
  end

  test "leaves out a virtual interface, one without a device, such as a container bridge" do
    status =
      current([
        {~c"docker0", up(addr: {172, 17, 0, 1})},
        {~c"eth0", up(addr: {192, 168, 10, 232})}
      ])

    assert Enum.map(status.interfaces, & &1.name) == ["eth0"]
  end

  test "reads the clock's UTC time to the second, and whether NTP synchronized it" do
    assert %{time: ~U[2026-11-11 14:53:12Z], synchronized: true} = current([])
    assert %{synchronized: false} = current([], fn -> false end)
  end

  test "measures the CPU's busy share over a short sample, and reads the load averages" do
    samples = :counters.new(1, [])

    status =
      BoardStatus.current(
        getifaddrs: fn -> {:ok, []} end,
        cpu_times: fn ->
          :counters.add(samples, 1, 1)
          if :counters.get(samples, 1) == 1, do: {100, 1_000}, else: {150, 1_200}
        end,
        sleep: fn _ms -> :ok end,
        loadavg: fn -> "0.52 0.48 0.40 1/123 4567\n" end,
        meminfo: fn -> "MemTotal: 8000000 kB\nMemAvailable: 3000000 kB\n" end
      )

    assert status.cpu_percent == 25.0
    assert status.load_average == [0.52, 0.48, 0.4]
    assert status.memory_percent == 62.5
  end

  test "reports neither where /proc cannot be read" do
    status =
      BoardStatus.current(
        getifaddrs: fn -> {:ok, []} end,
        cpu_times: fn -> nil end,
        sleep: fn _ms -> :ok end,
        loadavg: fn -> nil end,
        meminfo: fn -> nil end
      )

    assert {status.cpu_percent, status.load_average, status.memory_percent} == {nil, nil, nil}
  end

  test "reports no synchronization where NervesTime is missing, as on a host" do
    assert BoardStatus.current(getifaddrs: fn -> {:ok, []} end).synchronized == nil
  end

  test "lists no interface when they cannot be read" do
    assert BoardStatus.current(getifaddrs: fn -> {:error, :enotsup} end).interfaces == []
  end
end
