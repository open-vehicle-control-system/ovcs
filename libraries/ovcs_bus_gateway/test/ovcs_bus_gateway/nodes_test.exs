defmodule OvcsBusGateway.NodesTest do
  use ExUnit.Case, async: true

  alias OvcsBusGateway.{Envelope, Nodes}

  defp envelope(node, source, name, value, changed_at \\ 0, stale \\ false) do
    %Envelope{
      node: node,
      source: source,
      name: name,
      value: value,
      changed_at: changed_at,
      published_at: changed_at,
      stale: stale
    }
  end

  defp presence(node, connected?),
    do: envelope(node, "OvcsBusGateway.Collector", "connected", connected?, 0, nil)

  test "turns the presence into the node's connected and keeps it out of its signals" do
    nodes =
      Nodes.list([
        presence("vms", true),
        envelope("vms", "A", "speed", 3, 1_000),
        envelope("vms", "A", "gear", "drive", 2_000, true),
        presence("bridge-ros", false),
        envelope("infotainment", "B", "volume", 4)
      ])

    assert Enum.map(nodes, &{&1.id, &1.connected, length(&1.signals)}) == [
             {"bridge-ros", false, 0},
             {"infotainment", nil, 1},
             {"vms", true, 2}
           ]

    vms = List.last(nodes)
    assert Enum.map(vms.signals, & &1.name) == ["speed", "gear"]
    assert Nodes.stale_count(vms) == 1
    assert Nodes.last_change_at(vms) == 2_000
    assert Nodes.last_change_at(hd(nodes)) == nil
  end
end
