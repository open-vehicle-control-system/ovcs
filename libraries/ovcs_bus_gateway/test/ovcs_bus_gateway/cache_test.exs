defmodule OvcsBusGateway.CacheTest do
  use ExUnit.Case, async: false

  alias OvcsBusGateway.{Cache, Envelope}

  setup do
    start_supervised!(Cache)
    :ok
  end

  defp env(node, source, name, value) do
    %Envelope{
      node: node,
      source: source,
      name: name,
      value: value,
      changed_at: 0,
      published_at: 5
    }
  end

  test "keeps only the latest envelope per signal" do
    Cache.put_all([env("vms", "A", "speed", 1), env("vms", "A", "speed", 2)])

    assert [%{value: 2}] = Cache.select(%{})
  end

  test "select filters by node, source and name" do
    Cache.put_all([
      env("vms", "A", "speed", 1),
      env("bridge-ros", "B", "speed", 1),
      env("vms", "A", "gear", :drive)
    ])

    assert [%{name: "gear"}, %{name: "speed"}] = Cache.select(%{node: "vms"})
    assert [%{node: "bridge-ros"}] = Cache.select(%{source: "B"})
    assert [%{node: "bridge-ros"}, %{node: "vms"}] = Cache.select(%{name: "speed"})
    assert [] = Cache.select(%{node: "vms", name: "missing"})
  end

  test "select sorts by node, source and name" do
    Cache.put_all([
      env("vms", "A", "speed", 1),
      env("vms", "A", "gear", 1),
      env("bridge", "Z", "a", 1)
    ])

    assert [{"bridge", "Z", "a"}, {"vms", "A", "gear"}, {"vms", "A", "speed"}] =
             Enum.map(Cache.select(%{}), &Envelope.key/1)
  end

  test "mark_stale marks and returns the fresh envelopes received before a time" do
    Cache.put_all([%{env("vms", "A", "old", 1) | stale: false}])
    received_before = System.monotonic_time(:millisecond) + 1
    Process.sleep(2)

    Cache.put_all([
      %{env("vms", "A", "new", 1) | stale: false},
      %{env("vms", "A", "unknown", 1) | stale: nil}
    ])

    assert [%{name: "old", stale: true}] = Cache.mark_stale(received_before)
    assert {:ok, %{stale: true}} = Cache.fetch({"vms", "A", "old"})
    assert [] = Cache.mark_stale(received_before)
    assert [%{name: "new"}] = Cache.mark_stale(System.monotonic_time(:millisecond) + 1)
    assert {:ok, %{stale: nil}} = Cache.fetch({"vms", "A", "unknown"})
  end

  test "fetch returns the envelope of a signal" do
    envelope = env("vms", "A", "speed", 1)
    Cache.put_all([envelope])

    assert {:ok, ^envelope} = Cache.fetch({"vms", "A", "speed"})
    assert :error = Cache.fetch({"vms", "A", "gear"})
  end
end
