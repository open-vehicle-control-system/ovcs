defmodule VmsCore.Components.OVCS.RadioControl.ThrottleTest do
  @moduledoc """
  The brake deadband, which is a control-level interlock in disguise.

  `radio_breaking` is not just a brake: `Managers.ControlLevel` reads it
  to drop `:ros` back to `:radio` *and* to latch `forced_control_level`,
  so the only way out is cycling the switch down through the middle
  position. That makes a false positive expensive -- a trigger trimmed a
  hair below centre used to make `:ros` unreachable, and re-trigger the
  instant the operator switched back up.
  """
  use ExUnit.Case, async: true

  alias VmsCore.Components.OVCS.RadioControl.Throttle
  alias Cantastic.{Frame, Signal}
  alias OvcsBus.Message
  alias Decimal, as: D

  setup do
    OvcsBus.subscribe("messages")
    :ok
  end

  defp state do
    {:ok, state} = Throttle.init(%{radio_control_channel: 2})
    {:ok, :cancel} = :timer.cancel(state.loop_timer)
    state
  end

  # Drive one raw channel value through the component and read what it
  # puts on the bus, rather than inspecting state: `radio_breaking` is
  # only useful to the manager, which sees it over the bus.
  defp at(raw) do
    frame =
      {:handle_frame,
       %Frame{
         name: "radio_control_channels0",
         # An integer, as `kind: integer` in `0x2A0_radio_control_channels0.yml`
         # decodes it -- the component's bounds check compares the raw
         # value with `>`, and a Decimal there sorts above every integer
         # in Erlang term order, so a struct would silently be rejected
         # as out of range.
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
        {_throttle, breaking} = at(raw)
        refute breaking, "raw #{raw} reported braking with the trigger at rest"
      end
    end

    test "reports no throttle at exact centre" do
      assert {0.0, false} = at(1500)
    end
  end

  describe "a trigger actually pulled into reverse" do
    test "reports braking" do
      {throttle, breaking} = at(1400)
      assert breaking
      assert_in_delta throttle, -0.2, 1.0e-9
    end

    test "reports braking at full reverse" do
      {throttle, breaking} = at(1000)
      assert breaking
      assert_in_delta throttle, -1.0, 1.0e-9
    end
  end

  describe "forward" do
    test "is never braking" do
      for raw <- [1600, 1750, 2000] do
        {throttle, breaking} = at(raw)
        refute breaking
        assert throttle > 0.0
      end
    end
  end

  describe "the reading is the current one" do
    test "braking is computed from this frame, not the previous tick" do
      # It used to read `state.requested_throttle`, i.e. the value from
      # 10 ms ago. A takeover reported one loop late is the one thing
      # this signal must not do.
      {_throttle, breaking} = at(1000)
      assert breaking
    end
  end
end
