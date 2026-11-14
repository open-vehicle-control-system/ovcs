defmodule VmsCore.Components.OVCS.RosActuatorCommand.ThrottleTest do
  @moduledoc """
  The ROS throttle expiry, driven by the frame's `sequence`: a
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
    %{Freshness.new(500, now - 10_000) | sequence: 1, fresh_at_ms: now - 10_000, stale: false}
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
    assert_receive %Message{name: :requested_throttle, value: throttle, source: Throttle}
    {throttle, state}
  end

  defp emitted_braking(state) do
    {:noreply, state} = Throttle.handle_info(:loop, state)
    assert_receive %Message{name: :requested_braking, value: braking, source: Throttle}
    {braking, state}
  end

  describe "the braking request" do
    test "is the magnitude of a negative throttle" do
      {:noreply, state} = Throttle.handle_info(frame("-0.4", 2), stub_state())
      {braking, _state} = emitted_braking(state)
      assert D.equal?(braking, D.new("0.4"))
    end

    test "is zero while the throttle drives" do
      {:noreply, state} = Throttle.handle_info(frame("0.6", 2), stub_state())
      {braking, _state} = emitted_braking(state)
      assert D.equal?(braking, 0)
    end

    test "goes to zero with the throttle when the command goes stale" do
      {braking, _state} = emitted_braking(stub_state(%{requested_throttle: D.new("-0.8")}))
      assert D.equal?(braking, 0)
    end
  end

  describe "a sequence that stops changing" do
    test "zeroes the throttle, once, with a warning" do
      # Full throttle commanded, then the bridge goes quiet: the frame
      # may well keep arriving, retransmitted, with the same sequence.
      state = stub_state(%{requested_throttle: D.new(1)})
      {:noreply, state} = Throttle.handle_info(frame(1, 1), state)

      assert D.equal?(state.requested_throttle, D.new(1)),
             "a repeat was applied as input"

      {throttle, _} = emitted(state)

      assert D.equal?(throttle, D.new(0)),
             "the last throttle survived the input going away"
    end

    test "zeroes a braking request too" do
      {throttle, _} = emitted(stub_state(%{requested_throttle: D.new(-1)}))
      assert D.equal?(throttle, D.new(0))
    end

    test "the next new sample restores control with no latch to clear" do
      {_, expired} = emitted(stub_state(%{requested_throttle: D.new(1)}))
      {:noreply, recovered} = Throttle.handle_info(frame("0.5", 2), expired)
      {throttle, _} = emitted(recovered)
      assert D.equal?(throttle, D.new("0.5"))
    end
  end

  test "zeroes a recovery sample that expires before the next loop" do
    now_ms = System.monotonic_time(:millisecond)
    {_, expired} = emitted(stub_state())
    {:noreply, recovered} = Throttle.handle_info(frame("0.75", 2), expired)
    freshness = %{recovered.freshness | fresh_at_ms: now_ms - 10_000}

    {throttle, _state} = emitted(%{recovered | freshness: freshness})

    assert D.eq?(throttle, 0)
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
