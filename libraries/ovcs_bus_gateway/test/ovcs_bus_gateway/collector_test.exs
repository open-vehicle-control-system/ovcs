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

  defp presence(node_name, value) do
    %{node: node_name, source: "OvcsBusGateway.Collector", name: "connected", value: value}
  end

  test "publishes the presence of each node it starts a forwarder on, and of lost nodes" do
    Subscribers.subscribe()
    collector = start_supervised!({Collector, vehicle: OvcsMini})
    local = Atom.to_string(node())
    before = System.os_time(:millisecond)

    assert_receive {:ovcs_bus_gateway, [connected]}, 200
    assert Map.take(connected, [:node, :source, :name, :value]) == presence(local, true)
    assert connected.timestamp >= before
    assert [^connected] = Cache.select(%{source: "OvcsBusGateway.Collector"})

    send(collector, {:nodedown, :"gone@127.0.0.1"})
    assert_receive {:ovcs_bus_gateway, [disconnected]}, 200

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

    assert_receive :alive_checked, 100
    refute_receive :alive_checked, 900
    assert_receive :alive_checked, 300
    assert :sys.get_state(collector).forwarders == %{}
    assert Registry.lookup(OvcsBus, "messages") == []

    Agent.update(alive, fn _ -> true end)
    assert_receive :alive_checked, 1_200
    await_forwarder(node())

    OvcsBus.broadcast("messages", message(:speed, 4))
    assert_receive {:ovcs_bus_gateway, [%{name: "speed", value: 4}]}, 200
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
    assert_receive {:ovcs_bus_gateway, [%{name: "speed", value: 5}]}, 200
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
