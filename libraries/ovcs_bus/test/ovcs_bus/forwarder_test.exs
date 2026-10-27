defmodule OvcsBus.ForwarderTest do
  use ExUnit.Case, async: false

  alias OvcsBus.Forwarder
  alias OvcsBus.Message

  setup do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(OvcsBus) do
      start_supervised!({Phoenix.PubSub, name: OvcsBus})
    end

    :ok
  end

  defp start_forwarder(opts) do
    pid = spawn_link(Forwarder, :run, [self(), opts])
    await_subscribed(pid)
    pid
  end

  defp await_subscribed(pid, attempts \\ 200) do
    subscribed? = Enum.any?(Registry.lookup(OvcsBus, "messages"), fn {p, _} -> p == pid end)

    cond do
      subscribed? ->
        :ok

      attempts == 0 ->
        flunk("forwarder never subscribed")

      true ->
        Process.sleep(5)
        await_subscribed(pid, attempts - 1)
    end
  end

  defp message(name, value, source \\ A), do: %Message{name: name, value: value, source: source}

  defp collect_entries(acc, timeout) do
    receive do
      {:ovcs_bus_batch, _node, entries} -> collect_entries(acc ++ entries, timeout)
    after
      timeout -> acc
    end
  end

  test "sends the latest value of each changed signal once per tick" do
    pid = start_forwarder(interval: 60_000)

    for value <- 1..3, do: OvcsBus.broadcast("messages", message(:speed, value))
    send(pid, :tick)

    assert_receive {:ovcs_bus_batch, node, [{%Message{name: :speed, value: 3}, ts}]}, 100
    assert node == node()
    assert is_integer(ts)

    send(pid, :tick)
    refute_receive {:ovcs_bus_batch, _, _}, 60
  end

  test "keeps signals of different sources apart" do
    start_forwarder(interval: 20)

    OvcsBus.broadcast("messages", message(:speed, 1, A))
    OvcsBus.broadcast("messages", message(:speed, 2, B))

    assert_receive {:ovcs_bus_batch, _, entries}, 100

    assert entries |> Enum.map(fn {m, _} -> {m.source, m.value} end) |> Enum.sort() ==
             [{A, 1}, {B, 2}]
  end

  test "drops a value equal to the one already sent" do
    start_forwarder(interval: 20)

    OvcsBus.broadcast("messages", message(:gear, :parking))
    assert_receive {:ovcs_bus_batch, _, [{%Message{name: :gear}, _}]}, 100

    OvcsBus.broadcast("messages", message(:gear, :parking))
    refute_receive {:ovcs_bus_batch, _, _}, 60
  end

  test "sends a value again once it changed back" do
    start_forwarder(interval: 20)

    OvcsBus.broadcast("messages", message(:gear, :parking))
    assert_receive {:ovcs_bus_batch, _, _}, 100
    OvcsBus.broadcast("messages", message(:gear, :drive))
    assert_receive {:ovcs_bus_batch, _, [{%Message{value: :drive}, _}]}, 100
    OvcsBus.broadcast("messages", message(:gear, :parking))
    assert_receive {:ovcs_bus_batch, _, [{%Message{value: :parking}, _}]}, 100
  end

  test "keeps signals pending while the link is busy and reports skipped ticks" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    send_fun = fn dest, msg ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) < 2 do
        :nosuspend
      else
        send(dest, msg)
        :ok
      end
    end

    start_forwarder(interval: 20, report_interval: 50, send: send_fun)
    OvcsBus.broadcast("messages", message(:speed, 1))

    entries = collect_entries([], 200)

    assert Enum.any?(entries, fn {m, _} -> m.name == :speed and m.value == 1 end)

    assert Enum.any?(entries, fn {m, _} ->
             m.source == Forwarder and m.name == :skipped_ticks and m.value == 2
           end)
  end

  test "exits with its collector" do
    parent = self()

    collector =
      spawn(fn ->
        forwarder = Node.spawn_link(node(), Forwarder, :run, [self(), []])
        send(parent, {:forwarder, forwarder})
        Process.sleep(:infinity)
      end)

    assert_receive {:forwarder, forwarder}
    ref = Process.monitor(forwarder)

    Process.exit(collector, :kill)

    assert_receive {:DOWN, ^ref, :process, ^forwarder, _}, 500
  end

  test "exits when its collector exits normally" do
    parent = self()

    collector =
      spawn(fn ->
        forwarder = Node.spawn_link(node(), Forwarder, :run, [self(), []])
        send(parent, {:forwarder, forwarder})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:forwarder, forwarder}
    ref = Process.monitor(forwarder)

    send(collector, :stop)

    assert_receive {:DOWN, ^ref, :process, ^forwarder, _}, 500
  end
end
