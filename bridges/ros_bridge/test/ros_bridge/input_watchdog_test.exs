defmodule RosBridge.InputWatchdogTest do
  @moduledoc """
  Tests for the input-staleness state machine.

  Three properties matter, and each has a failure mode worse than
  having no watchdog at all:

    * **It starts stale.** A consumer that has never received an input
      must not emit a command. Starting fresh would mean the vehicle
      accepts whatever the emitter was initialised with until a
      timeout elapses from a start time that meant nothing.
    * **It reports transitions, not states.** At a 10 ms tick, a
      watchdog that reports staleness every tick produces a hundred
      log lines a second and buries whatever else went wrong.
    * **It recovers.** A watchdog that latches stale is a vehicle that
      never drives again after one dropped sample.
  """
  use ExUnit.Case, async: true

  alias RosBridge.InputWatchdog, as: Watchdog

  describe "a new watchdog" do
    test "starts stale, before any input has arrived" do
      assert Watchdog.stale?(Watchdog.new(500))
    end

    test "reports nothing on the first check, because it was already stale" do
      assert {:unchanged, _} = Watchdog.check(Watchdog.new(500))
    end

    test "rejects a timeout that is not a positive duration" do
      assert_raise FunctionClauseError, fn -> Watchdog.new(0) end
      assert_raise FunctionClauseError, fn -> Watchdog.new(-1) end
    end
  end

  describe "with input arriving" do
    test "a sample does not itself clear staleness — check/1 does" do
      # `seen/1` records, `check/1` decides. Keeping the transition in
      # one place is why the caller only has to handle it in one place.
      watchdog = Watchdog.new(500) |> Watchdog.seen()
      assert Watchdog.stale?(watchdog)

      {:fresh, watchdog} = Watchdog.check(watchdog)
      refute Watchdog.stale?(watchdog)
    end

    test "the recovery transition is reported once" do
      watchdog = Watchdog.new(500) |> Watchdog.seen()
      assert {:fresh, watchdog} = Watchdog.check(watchdog)
      assert {:unchanged, _} = Watchdog.check(watchdog)
    end

    test "a fresh input stays fresh across many checks" do
      {_, watchdog} = Watchdog.new(500) |> Watchdog.seen() |> Watchdog.check()

      watchdog =
        Enum.reduce(1..20, watchdog, fn _, acc ->
          {_, acc} = Watchdog.check(acc)
          acc
        end)

      refute Watchdog.stale?(watchdog)
    end
  end

  describe "when input stops" do
    # A 1 ms timeout with a real sleep, rather than injecting a clock:
    # the module reads `System.monotonic_time/1` directly, and a test
    # that stubbed that would be testing the stub. 20 ms of sleep for
    # the whole file is a fair price for exercising the real thing.
    test "the staleness transition is reported exactly once" do
      {:fresh, watchdog} = Watchdog.new(1) |> Watchdog.seen() |> Watchdog.check()
      Process.sleep(20)

      assert {:stale, watchdog} = Watchdog.check(watchdog)
      assert Watchdog.stale?(watchdog)
      assert {:unchanged, watchdog} = Watchdog.check(watchdog)
      assert {:unchanged, _} = Watchdog.check(watchdog)
    end

    test "a later sample recovers it" do
      {:fresh, watchdog} = Watchdog.new(1) |> Watchdog.seen() |> Watchdog.check()
      Process.sleep(20)
      {:stale, watchdog} = Watchdog.check(watchdog)

      assert {:fresh, watchdog} = watchdog |> Watchdog.seen() |> Watchdog.check()
      refute Watchdog.stale?(watchdog)
    end

    test "the timeout is honoured, not merely any elapsed time" do
      # A generous timeout must not expire just because a check
      # happened. This is what would break if `expired?` compared
      # against the wrong field.
      watchdog = Watchdog.new(10_000) |> Watchdog.seen()
      Process.sleep(20)
      assert {:fresh, watchdog} = Watchdog.check(watchdog)
      refute Watchdog.stale?(watchdog)
    end
  end
end
