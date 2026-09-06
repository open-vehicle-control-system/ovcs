defmodule VmsCore.Components.OVCS.RosCommand.FreshnessTest do
  @moduledoc """
  The sequence tracker. A retransmitted frame must not count as input,
  a stopped sequence must read as a lost input after the timeout, and
  every transition must be reported exactly once.
  """
  use ExUnit.Case, async: true

  alias VmsCore.Components.OVCS.RosCommand.Freshness

  @timeout 500

  test "starts stale and says so once the timeout has passed" do
    freshness = Freshness.new(@timeout, 0)
    assert Freshness.stale?(freshness)
    assert {:unchanged, freshness} = Freshness.check(freshness, 100)
    assert {:stale, freshness} = Freshness.check(freshness, 501)
    assert {:unchanged, _} = Freshness.check(freshness, 1_000)
  end

  test "a changing sequence is fresh input, a repeated one is not" do
    freshness = Freshness.new(@timeout, 0)
    assert {:new, freshness} = Freshness.observe(freshness, 7, 10)
    assert {:repeat, freshness} = Freshness.observe(freshness, 7, 20)
    assert {:new, _} = Freshness.observe(freshness, 8, 30)
  end

  test "reports fresh once, stale once, fresh again once" do
    freshness = Freshness.new(@timeout, 0)
    {:new, freshness} = Freshness.observe(freshness, 1, 10)
    assert {:fresh, freshness} = Freshness.check(freshness, 20)
    assert {:unchanged, freshness} = Freshness.check(freshness, 400)

    # The frame keeps arriving with the same sequence: still stale.
    {:repeat, freshness} = Freshness.observe(freshness, 1, 450)
    assert {:stale, freshness} = Freshness.check(freshness, 511)
    assert {:unchanged, freshness} = Freshness.check(freshness, 900)

    {:new, freshness} = Freshness.observe(freshness, 2, 1_000)
    assert {:fresh, _} = Freshness.check(freshness, 1_001)
  end

  test "the sequence wrapping to zero is still a change" do
    freshness = Freshness.new(@timeout, 0)
    {:new, freshness} = Freshness.observe(freshness, 255, 10)
    assert {:new, _} = Freshness.observe(freshness, 0, 20)
  end
end
