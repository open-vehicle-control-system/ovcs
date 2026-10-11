defmodule VmsCore.Components.OVCS.RadioControl.ThrottleTest do
  @moduledoc """
  The brake deadband, which is a control-level interlock in disguise.

  `radio_breaking` is not just a brake: `Managers.ControlLevel` reads it
  to drop `:ros` back to `:radio` *and* to latch `forced_control_level`,
  so the only way out is cycling the switch down through the middle
  position. That makes a false positive expensive: without a deadband a
  trigger trimmed a hair below centre makes `:ros` unreachable, and
  re-triggers the instant the operator switches back up.
  """
  use ExUnit.Case, async: true

  alias Cantastic.{Frame, Signal}
  alias OvcsBus.Message
  alias Decimal, as: D
  alias VmsCore.Components.OVCS.RadioControl.Throttle

  setup do
    OvcsBus.subscribe("messages")
    :ok
  end

  defp state do
    {:ok, state} = Throttle.init(%{radio_control_channel: 2})
    {:ok, :cancel} = :timer.cancel(state.loop_timer)
    state
  end

  # Reads the bus, not state: the manager only sees `radio_breaking` there.
  defp outputs_at(raw) do
    frame =
      {:handle_frame,
       %Frame{
         name: "radio_control_channels0",
         # An integer, as `0x2A0_radio_control_channels0.yml` decodes it: a
         # Decimal sorts above every integer in term order, so the bounds
         # check would reject it as out of range.
         signals: %{"channel2" => %Signal{name: "channel2", value: raw}}
       }}

    {:noreply, state} = Throttle.handle_info(frame, state())
    {:noreply, _state} = Throttle.handle_info(:loop, state)

    assert_receive %Message{name: :requested_throttle, value: throttle, source: Throttle}
    assert_receive %Message{name: :radio_breaking, value: breaking, source: Throttle}
    {D.to_float(throttle), breaking}
  end

  describe "a trigger at rest" do
    test "does not report braking, whatever the trim" do
      # 1480..1500 is the range a centred trigger actually sits in.
      for raw <- 1480..1500 do
        {_throttle, breaking} = outputs_at(raw)
        refute breaking, "raw #{raw} reported braking with the trigger at rest"
      end
    end

    test "reports no throttle at exact centre" do
      assert {0.0, false} = outputs_at(1500)
    end
  end

  describe "a trigger actually pulled into reverse" do
    test "reports braking" do
      {throttle, breaking} = outputs_at(1400)
      assert breaking
      assert_in_delta throttle, -0.2, 1.0e-9
    end

    test "reports braking at full reverse" do
      {throttle, breaking} = outputs_at(1000)
      assert breaking
      assert_in_delta throttle, -1.0, 1.0e-9
    end
  end

  describe "forward" do
    test "is never braking" do
      for raw <- [1600, 1750, 2000] do
        {throttle, breaking} = outputs_at(raw)
        refute breaking
        assert throttle > 0.0
      end
    end
  end

  describe "the reading is the current one" do
    test "braking is computed from this frame, not the previous tick" do
      # A takeover reported one loop late, from the previous tick's
      # value, is the one thing this signal must not do.
      {_throttle, breaking} = outputs_at(1000)
      assert breaking
    end
  end
end
