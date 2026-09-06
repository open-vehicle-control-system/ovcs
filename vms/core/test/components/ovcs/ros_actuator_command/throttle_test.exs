defmodule VmsCore.Components.OVCS.RosActuatorCommand.ThrottleTest do
  @moduledoc """
  The ROS throttle expiry, now driven by the frame's `sequence`: a
  bridge that stops producing samples, or stops talking, leaves a
  sequence that no longer changes, and the throttle must go to zero.

  Driven through `handle_info/2` against a stub state: `init/1`
  subscribes to Cantastic, which does not exist under
  `mix test --no-start`.
  """
  use ExUnit.Case, async: true

  alias Cantastic.{Frame, Signal}
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.RosActuatorCommand.Throttle
  alias VmsCore.Components.OVCS.RosCommand.Freshness

  # A tracker that saw a fresh sample long enough ago to have expired.
  defp expired_freshness do
    now = System.monotonic_time(:millisecond)
    %{Freshness.new(500, now - 10_000) | sequence: 1, fresh_at: now - 10_000, stale: false}
  end

  defp stub_state(overrides \\ %{}) do
    Map.merge(
      %{loop_timer: nil, freshness: expired_freshness(), requested_throttle: D.new(0)},
      overrides
    )
  end

  defp frame(throttle, sequence) do
    {:handle_frame,
     %Frame{
       name: "ros_actuator_command",
       signals: %{
         "throttle" => %Signal{name: "throttle", value: D.new(throttle)},
         "steering" => %Signal{name: "steering", value: D.new(0)},
         "direction" => %Signal{name: "direction", value: "forward"},
         "sequence" => %Signal{name: "sequence", value: sequence}
       }
     }}
  end

  setup do
    OvcsBus.subscribe("messages")
    :ok
  end

  defp emitted(state) do
    {:noreply, state} = Throttle.handle_info(:loop, state)
    assert_receive %Message{name: :requested_throttle, value: value, source: Throttle}
    {value, state}
  end

  describe "a sequence that stops changing" do
    test "zeroes the throttle, once, with a warning" do
      # Full throttle commanded, then the bridge goes quiet: the frame
      # may well keep arriving, retransmitted, with the same sequence.
      state = stub_state(%{requested_throttle: D.new(1)})
      {:noreply, state} = Throttle.handle_info(frame(1, 1), state)
      assert D.equal?(state.requested_throttle, D.new(1)), "a repeat was applied as input"

      {value, _} = emitted(state)
      assert D.equal?(value, D.new(0)), "the last throttle survived the input going away"
    end

    test "zeroes a braking request too" do
      {value, _} = emitted(stub_state(%{requested_throttle: D.new(-1)}))
      assert D.equal?(value, D.new(0))
    end

    test "the next new sample restores control with no latch to clear" do
      {_, expired} = emitted(stub_state(%{requested_throttle: D.new(1)}))
      {:noreply, recovered} = Throttle.handle_info(frame("0.5", 2), expired)
      {value, _} = emitted(recovered)
      assert D.equal?(value, D.new("0.5"))
    end
  end

  describe "normal operation" do
    test "a new sample is applied as is, in [-1, 1]" do
      {:noreply, state} = Throttle.handle_info(frame("0.25", 2), stub_state())
      assert D.equal?(state.requested_throttle, D.new("0.25"))
    end

    test "an unexpected message is ignored rather than fatal" do
      state = stub_state()

      for message <- [
            {:handle_missing_frame, :ovcs, "radio_control_channels0"},
            {:DOWN, make_ref(), :process, self(), :normal},
            :something_nobody_planned_for
          ] do
        assert {:noreply, ^state} = Throttle.handle_info(message, state)
      end
    end
  end
end
