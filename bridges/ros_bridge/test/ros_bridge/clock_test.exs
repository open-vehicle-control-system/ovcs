defmodule RosBridge.ClockTest.AcquiringSubscriber do
  @moduledoc """
  `subscribe/2` runs inside `Clock.init/1`, where `self()` is the Clock
  process, so the sample is in its mailbox before the selective receive
  runs. That tests the real lifecycle without a live ZenohClient.
  """
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
  followed and `RosBridge.Timing` must stay on wall clock. Sim time is
  opt-in, and a clock module that quietly changed stamps on the real
  vehicle would be far worse than one that did nothing.

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

  defp cdr_body(hex) do
    <<_encapsulation::binary-size(4), body::binary>> = Base.decode16!(hex, case: :lower)
    body
  end

  # The state `init/1` builds once it follows a clock; samples are adopted only while `following`.
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
      assert {:ok, %ClockMessage{clock: clock}, <<>>} = ClockMessage.parse(cdr_body(@clock_hex))
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
      # Stamps must still land near system time, not near zero.
      monotonic_ns = System.monotonic_time(:nanosecond)
      stamp_ns = Timing.ros_time_of(monotonic_ns)
      assert_in_delta stamp_ns, System.system_time(:nanosecond), 1_000_000_000
    end
  end

  describe "once a simulator clock arrives" do
    test "the offset projects monotonic time onto simulator time" do
      {:noreply, _state} = Clock.handle_info(clock_message(58, 643_000_000), tracking_state())

      assert Clock.following?()

      # A capture taken now stamps at roughly the simulator time just
      # received, not at wall-clock seconds.
      stamp_ns = Timing.ros_time_of(System.monotonic_time(:nanosecond))
      assert_in_delta stamp_ns, 58_643_000_000, 100_000_000
    end

    test "a system-time sample stamps on the simulator's time too" do
      {:noreply, _state} = Clock.handle_info(clock_message(58, 643_000_000), tracking_state())

      stamp = Timing.time_message_for_system_time(System.system_time(:nanosecond))
      assert_in_delta stamp.sec * 1_000_000_000 + stamp.nanosec, 58_643_000_000, 100_000_000
    end

    test "a stamp is nowhere near wall clock, which is the whole point" do
      {:noreply, _state} = Clock.handle_info(clock_message(58, 0), tracking_state())

      stamp_ns = Timing.ros_time_of(System.monotonic_time(:nanosecond))
      wall_ns = System.system_time(:nanosecond)

      assert abs(wall_ns - stamp_ns) > 1_000_000_000_000_000,
             "simulator stamps should be ~two decades from wall clock, not adjacent to it"
    end

    test "the offset tracks a clock that keeps advancing" do
      state = tracking_state()
      {:noreply, state} = Clock.handle_info(clock_message(10, 0), state)
      first_offset_ns = Clock.offset_ns()

      {:noreply, _state} = Clock.handle_info(clock_message(20, 0), state)
      second_offset_ns = Clock.offset_ns()

      # Ten simulated seconds passed in near-zero real time, so the
      # offset must have grown by about that much.
      assert_in_delta second_offset_ns - first_offset_ns, 10_000_000_000, 100_000_000
    end

    test "a stamp fits builtin_interfaces/Time without wrapping" do
      # `sec` is an int32, and a negative simulator stamp means the
      # offset was applied the wrong way round.
      {:noreply, _state} = Clock.handle_info(clock_message(58, 643_000_000), tracking_state())

      time = Timing.time_message_for(System.monotonic_time(:nanosecond))
      assert time.sec > 0
      assert time.sec < 2_147_483_647
      assert time.nanosec >= 0 and time.nanosec < 1_000_000_000
    end
  end

  describe "the real lifecycle, under a supervisor" do
    # A supervisor's `:shutdown` reaches `terminate/2` only when the
    # process traps exits, so these go through a real supervisor rather
    # than calling the callback.
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
    # Past the deadline the bridge is on wall clock for good: a late
    # sample switching timescales mid-run would poison tf2.
    test "the deadline leaves it on wall clock" do
      start_supervised!({Clock, %{subscriber: SilentSubscriber, acquire_timeout_ms: 5}})

      refute Clock.following?()

      assert_in_delta Timing.ros_time_of(System.monotonic_time(:nanosecond)),
                      System.system_time(:nanosecond),
                      1_000_000_000
    end

    test "a sample arriving after the deadline is ignored" do
      start_supervised!({Clock, %{subscriber: SilentSubscriber, acquire_timeout_ms: 5}})
      clock_pid = Process.whereis(Clock)

      send(
        clock_pid,
        {:ros_message,
         {"clock", %ClockMessage{clock: %Ros2.BuiltinInterfaces.Msg.Time{sec: 58, nanosec: 0}}}}
      )

      # Round-trip so the message above is definitely handled.
      _ = :sys.get_state(clock_pid)

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
