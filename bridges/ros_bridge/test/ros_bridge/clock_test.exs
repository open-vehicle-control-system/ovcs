# `subscribe/2` is called from inside `Clock.init/1`, so `self()` there
# is the Clock process itself — putting a sample in its mailbox before
# the selective receive runs. That lets the real lifecycle be tested
# without a live ZenohClient, and without poking at process state.
defmodule RosBridge.ClockTest.AcquiringSubscriber do
  alias Ros2.BuiltinInterfaces.Msg.Time
  alias Ros2.RosgraphMsgs.Msg.Clock, as: ClockMessage

  def subscribe(topic, _module) do
    send(self(), {:ros_message, {topic, %ClockMessage{clock: %Time{sec: 58, nanosec: 0}}}})
    :ok
  end

  def unsubscribe(_topic), do: :ok
end

defmodule RosBridge.ClockTest.SilentSubscriber do
  # Never delivers, so `init/1` reaches its deadline.
  def subscribe(_topic, _module), do: :ok
  def unsubscribe(_topic), do: :ok
end

defmodule RosBridge.ClockTest do
  @moduledoc """
  Tests for following a simulator clock.

  The property that matters most is the *absence* of an effect: on a
  vehicle, and in every other test in this suite, no `/clock` is being
  followed and `RosBridge.Timing` must behave exactly as it did before
  this existed. Sim time is opt-in, and a clock module that quietly
  changed stamps on the real vehicle would be far worse than one that
  did nothing.

  `async: false`, because the offset lives in `:persistent_term` and
  `:atomics` — process-independent by design, since it is read on
  every published message and cannot afford a `GenServer.call`. That
  makes it global state, so these tests own it exclusively and clean
  up after themselves.
  """
  use ExUnit.Case, async: false

  alias Ros2.RosgraphMsgs.Msg.Clock, as: ClockMessage
  alias RosBridge.{Clock, Timing}
  alias RosBridge.ClockTest.{AcquiringSubscriber, SilentSubscriber}

  @persistent_key RosBridge.Clock

  # Verbatim from `rclpy.serialization.serialize_message` on a Lyrical
  # runtime, including the 4-byte CDR encapsulation header that
  # `Ros2.RmwZenoh` strips before any `parse/1`.
  @clock_hex "000100003a000000c0665326"

  setup do
    on_exit(fn -> :persistent_term.erase(@persistent_key) end)
    :persistent_term.erase(@persistent_key)
    :ok
  end

  defp body(hex) do
    <<_encapsulation::binary-size(4), body::binary>> = Base.decode16!(hex, case: :lower)
    body
  end

  # What `init/1` builds once it has acquired a clock, without needing
  # a ZenohClient to subscribe to. `following: true` matters: samples
  # are only adopted while following, so that a late one after the
  # deadline cannot switch timescales mid-run.
  defp tracking_state do
    atomics = :atomics.new(2, signed: true)
    :persistent_term.put(@persistent_key, atomics)
    %{atomics: atomics, samples: 0, subscriber: SilentSubscriber, following: true}
  end

  defp clock_message(sec, nanosec) do
    {:ros_message,
     {"clock", %ClockMessage{clock: %Ros2.BuiltinInterfaces.Msg.Time{sec: sec, nanosec: nanosec}}}}
  end

  describe "parsing rosgraph_msgs/Clock" do
    test "reads the simulator time out of real bytes" do
      assert {:ok, %ClockMessage{clock: clock}, <<>>} = ClockMessage.parse(body(@clock_hex))
      assert clock.sec == 58
      assert clock.nanosec == 643_000_000
    end
  end

  describe "with no simulator clock" do
    test "there is no offset" do
      refute Clock.following?()
      assert Clock.offset_ns() == nil
    end

    test "Timing stays on wall clock" do
      # The regression that would matter on the vehicle: stamps must
      # still land near system time, not near zero.
      monotonic = System.monotonic_time(:nanosecond)
      stamped = Timing.ros_time_of(monotonic)
      assert_in_delta stamped, System.system_time(:nanosecond), 1_000_000_000
    end
  end

  describe "once a simulator clock arrives" do
    test "the offset projects monotonic time onto simulator time" do
      {:noreply, _state} = Clock.handle_info(clock_message(58, 643_000_000), tracking_state())

      assert Clock.following?()

      # A capture taken now should stamp at roughly the simulator time
      # we just saw — not at 1.78e9 seconds.
      stamped = Timing.ros_time_of(System.monotonic_time(:nanosecond))
      assert_in_delta stamped, 58_643_000_000, 100_000_000
    end

    test "a stamp is nowhere near wall clock, which is the whole point" do
      {:noreply, _state} = Clock.handle_info(clock_message(58, 0), tracking_state())

      stamped = Timing.ros_time_of(System.monotonic_time(:nanosecond))
      wall = System.system_time(:nanosecond)

      assert abs(wall - stamped) > 1_000_000_000_000_000,
             "simulator stamps should be ~two decades from wall clock, not adjacent to it"
    end

    test "the offset tracks a clock that keeps advancing" do
      state = tracking_state()
      {:noreply, state} = Clock.handle_info(clock_message(10, 0), state)
      first = Clock.offset_ns()

      {:noreply, _state} = Clock.handle_info(clock_message(20, 0), state)
      second = Clock.offset_ns()

      # Ten simulated seconds passed in near-zero real time, so the
      # offset must have grown by about that much.
      assert_in_delta second - first, 10_000_000_000, 100_000_000
    end

    test "a stamp fits builtin_interfaces/Time without wrapping" do
      # `sec` is an int32. A wall-clock stamp is fine today but a
      # simulator stamp being *negative* would mean the offset was
      # applied the wrong way round, which is the classic sign error
      # here.
      {:noreply, _state} = Clock.handle_info(clock_message(58, 643_000_000), tracking_state())

      time = Timing.time_message_for(System.monotonic_time(:nanosecond))
      assert time.sec > 0
      assert time.sec < 2_147_483_647
      assert time.nanosec >= 0 and time.nanosec < 1_000_000_000
    end
  end

  describe "the real lifecycle, under a supervisor" do
    # The first version of the shutdown test called `terminate/2` by
    # hand, so it passed while production did nothing: a `GenServer`
    # does not receive `terminate/2` from a supervisor's ordinary
    # `exit(pid, :shutdown)` unless it traps exits, and `init/1` did
    # not. Testing the callback tested the callback. These test the
    # guarantee.
    test "a sample delivered during init is adopted" do
      start_supervised!({Clock, %{subscriber: AcquiringSubscriber, acquire_timeout_ms: 5_000}})

      assert Clock.following?()

      assert_in_delta Timing.ros_time_of(System.monotonic_time(:nanosecond)),
                      58_000_000_000,
                      100_000_000
    end

    test "a supervised stop stops the offset being used" do
      start_supervised!({Clock, %{subscriber: AcquiringSubscriber, acquire_timeout_ms: 5_000}})
      assert Clock.following?()

      :ok = stop_supervised(Clock)

      refute Clock.following?(),
             "a stopped clock left a frozen offset behind, so every stamp would drift for ever"

      # And Timing is back on wall clock rather than using it.
      assert_in_delta Timing.ros_time_of(System.monotonic_time(:nanosecond)),
                      System.system_time(:nanosecond),
                      1_000_000_000
    end
  end

  describe "giving up is permanent" do
    # The review finding this exists for: the deadline logged
    # "continuing on wall clock" while the subscription stayed live, so
    # a sample arriving later silently switched timescales mid-run —
    # which is exactly the tf2-poisoning the blocking init prevents.
    test "the deadline leaves it on wall clock" do
      start_supervised!({Clock, %{subscriber: SilentSubscriber, acquire_timeout_ms: 5}})

      refute Clock.following?()

      assert_in_delta Timing.ros_time_of(System.monotonic_time(:nanosecond)),
                      System.system_time(:nanosecond),
                      1_000_000_000
    end

    test "a sample arriving after the deadline is ignored" do
      start_supervised!({Clock, %{subscriber: SilentSubscriber, acquire_timeout_ms: 5}})
      clock = Process.whereis(Clock)

      send(
        clock,
        {:ros_message,
         {"clock", %ClockMessage{clock: %Ros2.BuiltinInterfaces.Msg.Time{sec: 58, nanosec: 0}}}}
      )

      # Round-trip so the message above is definitely handled.
      _ = :sys.get_state(clock)

      refute Clock.following?(),
             "a late /clock sample switched the timescale mid-run, which corrupts tf2 for good"
    end
  end

  describe "unexpected input" do
    test "a message for another topic does not disturb the offset" do
      state = tracking_state()
      {:noreply, state} = Clock.handle_info(clock_message(58, 0), state)
      before = Clock.offset_ns()

      {:noreply, _state} =
        Clock.handle_info({:ros_message, {"something_else", %{unexpected: true}}}, state)

      assert Clock.offset_ns() == before
    end

    test "a stray message is ignored rather than fatal" do
      state = tracking_state()
      assert {:noreply, ^state} = Clock.handle_info(:unplanned, state)
    end
  end
end
