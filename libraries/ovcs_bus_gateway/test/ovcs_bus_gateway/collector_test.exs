defmodule OvcsBusGateway.CollectorTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias OvcsBusGateway.{Cache, Collector, Subscribers}
  alias OvcsBusGateway.Test.Peer

  setup do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    unless Process.whereis(OvcsBus) do
      start_supervised!({Phoenix.PubSub, name: OvcsBus})
    end

    start_supervised!(Subscribers)
    start_supervised!(Cache)
    :ok
  end

  defp message(name, value),
    do: %OvcsBus.Message{name: name, value: value, source: VmsCore.Vehicle}

  defp await_forwarder(node, attempts \\ 200) do
    cond do
      :erpc.call(node, Registry, :lookup, [OvcsBus, "messages"]) != [] ->
        :ok

      attempts == 0 ->
        flunk("no forwarder subscribed on #{node}")

      true ->
        Process.sleep(5)
        await_forwarder(node, attempts - 1)
    end
  end

  defp receive_from(node_name, timeout, source \\ "VmsCore.Vehicle") do
    receive do
      {:ovcs_bus_gateway, envelopes} ->
        if Enum.any?(envelopes, &(&1.node == node_name and &1.source == source)),
          do: envelopes,
          else: receive_from(node_name, timeout, source)
    after
      timeout -> flunk("no envelope from #{node_name}")
    end
  end

  test "caches and dispatches what the local bus publishes" do
    start_supervised!({Collector, vehicle: OvcsMini})
    Subscribers.subscribe()
    await_forwarder(node())

    OvcsBus.broadcast("messages", message(:speed, 3))

    assert_receive {:ovcs_bus_gateway, [%{name: "speed", value: 3, source: "VmsCore.Vehicle"}]},
                   200

    assert [%{name: "speed"}] = Cache.select(%{name: "speed"})
  end

  test "stamps each envelope with the change and publish times of its batch entry" do
    collector = start_supervised!({Collector, vehicle: OvcsMini, alive?: fn -> false end})
    Subscribers.subscribe()

    send(collector, {:ovcs_bus_batch, node(), [{message(:speed, 6), 1_000, 4_000}]})

    assert_receive {:ovcs_bus_gateway,
                    [%{name: "speed", changed_at: 1_000, published_at: 4_000, stale: false}]},
                   200
  end

  test "accepts the two-element entries of an older forwarder and skips unknown ones" do
    collector = start_supervised!({Collector, vehicle: OvcsMini, alive?: fn -> false end})
    Subscribers.subscribe()

    entries = [{message(:speed, 6), 2_000}, :unknown, {message(:gear, :drive), 1_000, 3_000}]

    log =
      capture_log([level: :debug], fn ->
        send(collector, {:ovcs_bus_batch, node(), entries})

        assert_receive {:ovcs_bus_gateway,
                        [
                          %{name: "speed", changed_at: 2_000, published_at: nil, stale: nil},
                          %{name: "gear", changed_at: 1_000, published_at: 3_000, stale: false}
                        ]},
                       200
      end)

    assert log =~ "skipped an unknown batch entry from #{node()}: :unknown"
    assert Process.alive?(collector)
  end

  test "skips a batch that is not a list" do
    collector = start_supervised!({Collector, vehicle: OvcsMini, alive?: fn -> false end})
    Subscribers.subscribe()

    log =
      capture_log([level: :debug], fn ->
        send(collector, {:ovcs_bus_batch, node(), :not_a_list})
        refute_receive {:ovcs_bus_gateway, _}, 50
      end)

    assert log =~ "skipped an unknown batch from #{node()}: :not_a_list"
    assert Process.alive?(collector)
  end

  defp start_sweeping_collector do
    start_supervised!(
      {Collector,
       vehicle: OvcsMini, alive?: fn -> false end, stale_after: 50, stale_check_interval: 10}
    )
  end

  test "marks a signal stale once it was not received for the stale delay, once" do
    collector = start_sweeping_collector()
    Subscribers.subscribe()

    send(collector, {:ovcs_bus_batch, node(), [{message(:speed, 6), 1_000, 4_000}]})
    assert_receive {:ovcs_bus_gateway, [%{name: "speed", stale: false}]}, 1_000
    refute_receive {:ovcs_bus_gateway, _}, 30

    assert_receive {:ovcs_bus_gateway, [%{name: "speed", published_at: 4_000, stale: true}]},
                   1_000

    assert {:ok, %{stale: true}} =
             Cache.fetch({Atom.to_string(node()), "VmsCore.Vehicle", "speed"})

    refute_receive {:ovcs_bus_gateway, _}, 150

    send(collector, {:ovcs_bus_batch, node(), [{message(:speed, 6), 1_000, 5_000}]})

    assert_receive {:ovcs_bus_gateway, [%{name: "speed", published_at: 5_000, stale: false}]},
                   1_000
  end

  test "never sweeps signals of unknown staleness" do
    collector = start_sweeping_collector()
    Subscribers.subscribe()

    send(collector, {:ovcs_bus_batch, node(), [{message(:speed, 6), 2_000}]})
    assert_receive {:ovcs_bus_gateway, [%{name: "speed", stale: nil}]}, 1_000
    refute_receive {:ovcs_bus_gateway, _}, 200
  end

  defp presence(node_name, value) do
    %{node: node_name, source: "OvcsBusGateway.Collector", name: "connected", value: value}
  end

  test "publishes the presence of each node it starts a forwarder on, and of lost nodes" do
    Subscribers.subscribe()
    collector = start_supervised!({Collector, vehicle: OvcsMini})
    local = Atom.to_string(node())
    before = System.os_time(:millisecond)

    assert_receive {:ovcs_bus_gateway, [connected]}, 1_000
    assert Map.take(connected, [:node, :source, :name, :value]) == presence(local, true)
    assert connected.changed_at >= before
    assert connected.published_at == connected.changed_at
    assert connected.stale == nil
    assert [^connected] = Cache.select(%{source: "OvcsBusGateway.Collector"})

    send(collector, {:nodedown, :"gone@127.0.0.1"})
    assert_receive {:ovcs_bus_gateway, [disconnected]}, 1_000

    assert Map.take(disconnected, [:node, :source, :name, :value]) ==
             presence("gone@127.0.0.1", false)

    assert [%{value: false}] = Cache.select(%{node: "gone@127.0.0.1"})
  end

  test "waits for distribution" do
    test = self()
    alive = start_supervised!({Agent, fn -> false end})

    alive? = fn ->
      send(test, :alive_checked)
      Agent.get(alive, & &1)
    end

    collector = start_supervised!({Collector, vehicle: OvcsMini, alive?: alive?})
    Subscribers.subscribe()

    assert_receive :alive_checked, 1_000
    refute_receive :alive_checked, 900
    assert_receive :alive_checked, 1_000
    assert :sys.get_state(collector).forwarders == %{}
    assert Registry.lookup(OvcsBus, "messages") == []

    Agent.update(alive, fn _ -> true end)
    assert_receive :alive_checked, 1_200
    await_forwarder(node())

    OvcsBus.broadcast("messages", message(:speed, 4))
    assert_receive {:ovcs_bus_gateway, [%{name: "speed", value: 4}]}, 1_000
  end

  test "replaces a forwarder that dies while its node stays connected" do
    collector = start_supervised!({Collector, vehicle: OvcsMini})
    Subscribers.subscribe()
    await_forwarder(node())

    [forwarder] = Map.keys(:sys.get_state(collector).forwarders)
    Process.exit(forwarder, :kill)
    await_replacement(collector, forwarder)
    await_forwarder(node())

    OvcsBus.broadcast("messages", message(:speed, 5))
    assert_receive {:ovcs_bus_gateway, [%{name: "speed", value: 5}]}, 1_000
  end

  defp await_replacement(collector, old, attempts \\ 300) do
    case Map.keys(:sys.get_state(collector).forwarders) do
      [pid] when pid != old ->
        :ok

      _ when attempts == 0 ->
        flunk("forwarder not replaced")

      _ ->
        Process.sleep(5)
        await_replacement(collector, old, attempts - 1)
    end
  end

  @tag :distributed
  test "collects from a node that joins later" do
    start_supervised!({Collector, vehicle: OvcsMini})
    Subscribers.subscribe()
    {:ok, peer, peer_node} = Peer.start()
    await_forwarder(peer_node)

    :ok = :peer.call(peer, OvcsBus, :broadcast, ["messages", message(:speed, 7)])

    assert [%{name: "speed", value: 7}] = receive_from(Atom.to_string(peer_node), 500)
    Peer.stop(peer)
  end

  defp occurrences(log, text), do: length(String.split(log, text)) - 1

  @tag :distributed
  test "does not retry a node outside the mesh that has no OvcsBus" do
    {peer_node, log} =
      with_log(fn ->
        collector = start_supervised!({Collector, vehicle: OvcsMini, peers: fn -> [] end})
        {:ok, peer, peer_node} = Peer.start_without_bus()
        Process.sleep(1_500)
        refute peer_node in Map.values(:sys.get_state(collector).forwarders)
        Peer.stop(peer)
        peer_node
      end)

    assert occurrences(log, "starting a forwarder on #{peer_node}") == 1
    assert occurrences(log, "#{peer_node} has no OvcsBus") == 1
  end

  @tag :distributed
  test "keeps retrying a mesh peer whose OvcsBus is not loaded yet" do
    {peer_node, log} =
      with_log(fn ->
        {:ok, peer, peer_node} = Peer.start_without_bus()
        start_supervised!({Collector, vehicle: OvcsMini, peers: fn -> [peer_node] end})
        Process.sleep(2_500)
        Peer.stop(peer)
        peer_node
      end)

    assert occurrences(log, "starting a forwarder on #{peer_node}") >= 2
    assert log =~ "[info] OvcsBusGateway.Collector forwarder on #{peer_node} exited: {:undef"
    refute log =~ "[warning]"
  end

  @tag :distributed
  test "forwarder restarts on nodeup" do
    collector = start_supervised!({Collector, vehicle: OvcsMini})
    Subscribers.subscribe()
    name = :peer.random_name()

    {:ok, peer, peer_node} = Peer.start(name)
    peer_name = Atom.to_string(peer_node)
    assert [%{value: true}] = receive_from(peer_name, 500, "OvcsBusGateway.Collector")
    await_forwarder(peer_node)
    Peer.stop(peer)
    assert [%{value: false}] = receive_from(peer_name, 500, "OvcsBusGateway.Collector")

    {:ok, peer, ^peer_node} = Peer.start(name)
    assert [%{value: true}] = receive_from(peer_name, 500, "OvcsBusGateway.Collector")
    await_forwarder(peer_node)

    :ok = :peer.call(peer, OvcsBus, :broadcast, ["messages", message(:speed, 9)])

    assert [%{name: "speed", value: 9}] = receive_from(Atom.to_string(peer_node), 500)
    assert Process.alive?(collector)
    Peer.stop(peer)
  end
end
