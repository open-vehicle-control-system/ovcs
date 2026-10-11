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

    test "reports :silent once the startup grace has passed and nothing has arrived" do
      # `:silent`, not `:unchanged`: a consumer subscribed to a topic
      # nobody publishes on must say so, because nothing downstream can
      # tell -- the CAN emitter goes on sending well-formed zeros.
      watchdog = Watchdog.new(1, 1)
      Process.sleep(5)

      assert {:silent, watchdog} = Watchdog.check(watchdog)
      assert Watchdog.stale?(watchdog)
    end

    test "holds :silent until then, because a normal boot has not gone wrong yet" do
      # The default grace outlasts a Zenoh session coming up, which takes
      # longer than an input timeout. With a 1 ms timeout the input is
      # long expired, so only the grace can be holding `:silent` back.
      watchdog = Watchdog.new(1)

      Process.sleep(5)
      assert {:unchanged, watchdog} = Watchdog.check(watchdog)
      assert Watchdog.stale?(watchdog)
    end

    test "rejects a startup grace that is not a positive duration" do
      assert_raise FunctionClauseError, fn -> Watchdog.new(500, 0) end
      assert_raise FunctionClauseError, fn -> Watchdog.new(500, -1) end
    end

    test "says it once, not once per tick" do
      watchdog = Watchdog.new(1, 1)
      Process.sleep(5)

      {:silent, watchdog} = Watchdog.check(watchdog)
      assert {:unchanged, watchdog} = Watchdog.check(watchdog)
      assert {:unchanged, _} = Watchdog.check(watchdog)
    end

    test ":silent is not repeated as :stale once a sample has arrived and gone" do
      # The two edges are different diagnoses -- a setup mistake versus
      # a runtime loss -- so an input that worked and stopped must
      # report :stale even though the watchdog was :silent before it.
      watchdog = Watchdog.new(1, 1)
      Process.sleep(5)

      {:silent, watchdog} = Watchdog.check(watchdog)
      {:fresh, watchdog} = watchdog |> Watchdog.seen() |> Watchdog.check()

      Process.sleep(5)
      assert {:stale, _} = Watchdog.check(watchdog)
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
    # A real sleep rather than an injected clock: the module reads
    # `System.monotonic_time/1` directly.
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
