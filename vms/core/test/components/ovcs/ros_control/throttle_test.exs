defmodule VmsCore.Components.OVCS.ROSControl.ThrottleTest do
  @moduledoc """
  Tests for the ROS throttle expiry.

  This is the failsafe that gates autonomous driving: without it a ROS
  bridge that stops talking leaves the last commanded throttle applied
  indefinitely, because `handle_frame` is the only thing that moves
  `raw_value` while `emit/1` runs every 10 ms regardless.

  Driven through `handle_info/2` against a stub state, the way
  `VmsCore.Managers.GearTest` drives its manager: `init/1` subscribes
  to Cantastic and enables a frame watcher, neither of which exists
  under `mix test --no-start`, and none of them is what is under test.
  """
  use ExUnit.Case, async: true

  alias Cantastic.{Frame, Signal}
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.ROSControl.Throttle

  @range 2 ** 31 - 1

  defp stub_state(overrides \\ %{}) do
    Map.merge(%{loop_timer: nil, raw_value: 0, requested_throttle: D.new(0)}, overrides)
  end

  defp frame(raw_value) do
    {:handle_frame,
     %Frame{
       name: "ros_control1",
       signals: %{
         "throttle" => %Signal{name: "throttle", value: raw_value},
         "steering" => %Signal{name: "steering", value: 0}
       }
     }}
  end

  # Once per test, not once per assertion. `Phoenix.PubSub.subscribe`
  # is not idempotent: subscribing inside the helper gave the Nth call
  # N registrations, so each broadcast delivered N copies, one was
  # consumed and the rest queued -- and from the third call on
  # `assert_receive` selectively matched a *previous* iteration's
  # message. A loop over inputs then checked the input before it, and
  # its last case was never checked at all.
  #
  # Each ExUnit test runs in its own process, so one subscription per
  # test is exactly the right scope and `async: true` still holds.
  setup do
    OvcsBus.subscribe("messages")
    :ok
  end

  # What the component would put on the bus on its next tick.
  defp emitted(state) do
    {:noreply, _state} = Throttle.handle_info(:loop, state)
    assert_receive %Message{name: :requested_throttle, value: value, source: Throttle}
    value
  end

  describe "a frame that stops arriving" do
    test "zeroes the throttle" do
      # Full throttle commanded, then the bridge goes quiet.
      state = stub_state(%{raw_value: @range})
      assert D.equal?(emitted(state), D.new(1))

      {:noreply, expired} =
        Throttle.handle_info({:handle_missing_frame, :ovcs, "ros_control1"}, state)

      assert D.equal?(emitted(expired), D.new(0)),
             "the last commanded throttle survived the bridge going away"
    end

    test "zeroes a braking request too, not just a driving one" do
      # A negative request is regenerative braking. Holding *that*
      # indefinitely is also wrong, so the expiry is symmetric.
      state = stub_state(%{raw_value: -@range})
      assert D.equal?(emitted(state), D.new(-1))

      {:noreply, expired} =
        Throttle.handle_info({:handle_missing_frame, :ovcs, "ros_control1"}, state)

      assert D.equal?(emitted(expired), D.new(0))
    end

    test "the next frame to arrive restores control with no further ceremony" do
      # Recovery needs no code of its own, which is worth pinning: a
      # latch would have to be cleared somewhere, and a forgotten latch
      # is a vehicle that never drives again after one dropped frame.
      {:noreply, expired} =
        Throttle.handle_info(
          {:handle_missing_frame, :ovcs, "ros_control1"},
          stub_state(%{raw_value: @range})
        )

      {:noreply, recovered} = Throttle.handle_info(frame(div(@range, 2)), expired)

      assert_in_delta recovered.requested_throttle |> D.to_float(), 0.0, 1.0
      assert_in_delta emitted(recovered) |> D.to_float(), 0.5, 0.001
    end
  end

  describe "normal operation is unchanged" do
    test "a commanded throttle is scaled onto 0..1" do
      assert_in_delta emitted(stub_state(%{raw_value: @range})) |> D.to_float(), 1.0, 0.001
      assert_in_delta emitted(stub_state(%{raw_value: 0})) |> D.to_float(), 0.0, 0.001
    end

    test "an arriving frame sets the raw value" do
      {:noreply, state} = Throttle.handle_info(frame(1234), stub_state())
      assert state.raw_value == 1234
    end

    test "an unexpected message is ignored rather than fatal" do
      # The subscription is frame-scoped, so a missing-frame event for
      # another frame should not reach this process in practice — but
      # something eventually will: a late reply, a monitor going down.
      # Without a catch-all clause that killed the throttle path, and a
      # gap in throttle emission is worse than doing nothing. The other
      # two clauses below are the messages that genuinely cannot be
      # matched by the specific ones.
      state = stub_state(%{raw_value: @range})

      for message <- [
            {:handle_missing_frame, :ovcs, "radio_control_channels0"},
            {:DOWN, make_ref(), :process, self(), :normal},
            :something_nobody_planned_for
          ] do
        assert {:noreply, ^state} = Throttle.handle_info(message, state),
               "#{inspect(message)} was not ignored"
      end
    end
  end
end
