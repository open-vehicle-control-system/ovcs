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

  # Batch entries received until `done?` holds for them, or `timeout` passes without a batch.
  defp collect_until(done?, timeout, acc \\ []) do
    if done?.(acc) do
      acc
    else
      receive do
        {:ovcs_bus_batch, _node, entries} -> collect_until(done?, timeout, acc ++ entries)
      after
        timeout -> acc
      end
    end
  end

  test "sends the latest value of each changed signal once per tick" do
    pid = start_forwarder(interval: 60_000)

    for value <- 1..3, do: OvcsBus.broadcast("messages", message(:speed, value))
    send(pid, :tick)

    assert_receive {:ovcs_bus_batch, node,
                    [{%Message{name: :speed, value: 3}, changed_at, published_at}]},
                   1_000

    assert node == node()
    assert is_integer(changed_at)
    assert published_at == changed_at

    send(pid, :tick)
    refute_receive {:ovcs_bus_batch, _, _}, 60
  end

  test "keeps signals of different sources apart" do
    start_forwarder(interval: 20)

    OvcsBus.broadcast("messages", message(:speed, 1, A))
    OvcsBus.broadcast("messages", message(:speed, 2, B))

    assert_receive {:ovcs_bus_batch, _, entries}, 1_000

    assert entries |> Enum.map(fn {m, _, _} -> {m.source, m.value} end) |> Enum.sort() ==
             [{A, 1}, {B, 2}]
  end

  test "drops a value equal to the one already sent" do
    start_forwarder(interval: 20)

    OvcsBus.broadcast("messages", message(:gear, :parking))
    assert_receive {:ovcs_bus_batch, _, [{%Message{name: :gear}, _, _}]}, 1_000

    OvcsBus.broadcast("messages", message(:gear, :parking))
    refute_receive {:ovcs_bus_batch, _, _}, 60
  end

  test "sends a value again once it changed back" do
    start_forwarder(interval: 20)

    OvcsBus.broadcast("messages", message(:gear, :parking))
    assert_receive {:ovcs_bus_batch, _, _}, 1_000
    OvcsBus.broadcast("messages", message(:gear, :drive))
    assert_receive {:ovcs_bus_batch, _, [{%Message{value: :drive}, _, _}]}, 1_000
    OvcsBus.broadcast("messages", message(:gear, :parking))
    assert_receive {:ovcs_bus_batch, _, [{%Message{value: :parking}, _, _}]}, 1_000
  end

  test "refreshes a signal republished with the same value once per refresh interval" do
    pid = start_forwarder(interval: 60_000, refresh_interval: 60_000)

    OvcsBus.broadcast("messages", message(:gear, :parking))
    send(pid, :tick)

    assert_receive {:ovcs_bus_batch, _,
                    [{%Message{value: :parking}, changed_at, first_published_at}]},
                   1_000

    Process.sleep(2)
    OvcsBus.broadcast("messages", message(:gear, :parking))
    OvcsBus.broadcast("messages", message(:gear, :parking))
    send(pid, :tick)
    refute_receive {:ovcs_bus_batch, _, _}, 60

    send(pid, :refresh)
    send(pid, :tick)

    assert_receive {:ovcs_bus_batch, _,
                    [{%Message{value: :parking}, ^changed_at, refreshed_published_at}]},
                   1_000

    assert refreshed_published_at > first_published_at

    send(pid, :refresh)
    send(pid, :tick)
    refute_receive {:ovcs_bus_batch, _, _}, 60
  end

  test "does not refresh a signal that was not republished" do
    pid = start_forwarder(interval: 60_000, refresh_interval: 60_000)

    OvcsBus.broadcast("messages", message(:gear, :parking))
    send(pid, :tick)
    assert_receive {:ovcs_bus_batch, _, [_entry]}, 1_000

    send(pid, :refresh)
    send(pid, :tick)
    refute_receive {:ovcs_bus_batch, _, _}, 60
  end

  test "sends a changed value on the next tick, without waiting for a refresh" do
    pid = start_forwarder(interval: 60_000, refresh_interval: 60_000)

    OvcsBus.broadcast("messages", message(:gear, :parking))
    send(pid, :tick)
    assert_receive {:ovcs_bus_batch, _, [{_message, first_changed_at, _published_at}]}, 1_000

    Process.sleep(2)
    OvcsBus.broadcast("messages", message(:gear, :drive))
    send(pid, :tick)

    assert_receive {:ovcs_bus_batch, _, [{%Message{value: :drive}, changed_at, changed_at}]},
                   1_000

    assert changed_at > first_changed_at
  end

  test "refreshes on its own every refresh interval" do
    start_forwarder(interval: 10, refresh_interval: 50)

    OvcsBus.broadcast("messages", message(:gear, :parking))
    assert_receive {:ovcs_bus_batch, _, [{_message, changed_at, _published_at}]}, 1_000

    OvcsBus.broadcast("messages", message(:gear, :parking))

    assert_receive {:ovcs_bus_batch, _,
                    [{%Message{value: :parking}, ^changed_at, _published_at}]},
                   1_000
  end

  test "a change after a refresh held back by a busy link replaces the refresh" do
    {:ok, busy} = Agent.start_link(fn -> false end)

    send_fun = fn dest, msg ->
      if Agent.get(busy, & &1), do: :nosuspend, else: send(dest, msg)
    end

    pid =
      start_forwarder(
        interval: 60_000,
        refresh_interval: 60_000,
        report_interval: 60_000,
        send: send_fun
      )

    OvcsBus.broadcast("messages", message(:gear, :parking))
    send(pid, :tick)
    assert_receive {:ovcs_bus_batch, _, [{_message, _changed_at, first_published_at}]}, 1_000

    Agent.update(busy, fn _ -> true end)
    Process.sleep(2)
    OvcsBus.broadcast("messages", message(:gear, :parking))
    send(pid, :refresh)
    send(pid, :tick)
    refute_receive {:ovcs_bus_batch, _, _}, 60

    Process.sleep(2)
    OvcsBus.broadcast("messages", message(:gear, :drive))
    send(pid, :refresh)
    Agent.update(busy, fn _ -> false end)
    send(pid, :tick)

    assert_receive {:ovcs_bus_batch, _, [{%Message{value: :drive}, changed_at, published_at}]},
                   1_000

    assert changed_at == published_at
    assert published_at > first_published_at
    refute_receive {:ovcs_bus_batch, _, _}, 60
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

    speed? = fn entries ->
      Enum.any?(entries, fn {m, _, _} -> m.name == :speed and m.value == 1 end)
    end

    skipped? = fn entries ->
      Enum.any?(entries, fn {m, _, _} ->
        m.source == Forwarder and m.name == :skipped_ticks and m.value == 2
      end)
    end

    entries = collect_until(&(speed?.(&1) and skipped?.(&1)), 2_000)

    assert speed?.(entries)
    assert skipped?.(entries)
  end

  test "republishes the skipped-tick total every report interval, so it is refreshed" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    send_fun = fn dest, msg ->
      if Agent.get_and_update(calls, &{&1, &1 + 1}) < 1, do: :nosuspend, else: send(dest, msg)
    end

    pid =
      start_forwarder(
        interval: 60_000,
        refresh_interval: 60_000,
        report_interval: 60_000,
        send: send_fun
      )

    OvcsBus.broadcast("messages", message(:speed, 1))
    send(pid, :tick)
    send(pid, :report)
    send(pid, :tick)
    assert_receive {:ovcs_bus_batch, _, entries}, 1_000
    assert Enum.any?(entries, fn {m, _, _} -> m.name == :skipped_ticks and m.value == 1 end)

    send(pid, :report)
    send(pid, :refresh)
    send(pid, :tick)

    assert_receive {:ovcs_bus_batch, _, [{%Message{name: :skipped_ticks, value: 1}, _, _}]}, 1_000
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
