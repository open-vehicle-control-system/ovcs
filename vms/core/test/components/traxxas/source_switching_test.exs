defmodule VmsCore.Components.Traxxas.SourceSwitchingTest do
  @moduledoc """
  The drivetrain follows whichever commander `Managers.ControlLevel`
  names, and stops when it names none.

  That second half is the reason this file exists. The manager selects
  sources per control level, and a level with no commander — `:manual`
  on OVCS Mini, which has no pedals — selects `nil`. The message
  handler for `:requested_throttle` gates on the source, so with no
  source **no message matches and the last request persists**. Left
  alone, switching the transmitter to the safe position would leave
  the vehicle driving at whatever it was last told.

  Same family as the stale-CAN-frame hazard: the value is held rather
  than expired, and nothing about the held value announces itself.

  Driven through `handle_info/2` against a stub state, the way
  `VmsCore.Managers.GearTest` does — `init/1` subscribes to the bus
  and starts a timer, neither of which is under test.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.Traxxas.{Steering, Throttle}

  @manager ControlLevelManager
  @commander SomeRosCommander

  defp steering_state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        controller: nil,
        external_pwm_id: 0,
        selected_control_level_source: @manager,
        requested_steering_source: @commander,
        requested_steering: D.new("0.7"),
        steering: D.new(0)
      },
      overrides
    )
  end

  defp throttle_state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        controller: nil,
        external_pwm_id: 1,
        selected_control_level_source: @manager,
        requested_throttle_source: @commander,
        requested_throttle: D.new("0.6"),
        throttle: D.new(0)
      },
      overrides
    )
  end

  defp source_message(name, value, source), do: %Message{name: name, value: value, source: source}

  describe "a level that commands nothing" do
    test "zeroes the throttle rather than holding it" do
      # The dangerous case: driving at 0.6, switched to a level with no
      # commander. Holding would keep the vehicle moving.
      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, nil, @manager),
          throttle_state()
        )

      assert D.equal?(state.requested_throttle, D.new(0)),
             "the last throttle survived a switch to a level with no commander"

      assert state.requested_throttle_source == nil
    end

    test "zeroes the steering too, so the wheels centre" do
      {:noreply, state} =
        Steering.handle_info(
          source_message(:requested_steering_source, nil, @manager),
          steering_state()
        )

      assert D.equal?(state.requested_steering, D.new(0))
    end
  end

  describe "switching between commanders" do
    test "the new source is adopted and the current request is kept" do
      # Not a safety transition — one commander handing to another —
      # so the vehicle should not lurch to zero mid-handover. The next
      # message from the new source overwrites it anyway.
      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, AnotherCommander, @manager),
          throttle_state()
        )

      assert state.requested_throttle_source == AnotherCommander
      assert D.equal?(state.requested_throttle, D.new("0.6"))
    end

    test "a request from the newly selected source is accepted" do
      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, AnotherCommander, @manager),
          throttle_state()
        )

      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle, D.new("0.25"), AnotherCommander),
          state
        )

      assert D.equal?(state.requested_throttle, D.new("0.25"))
    end

    test "a request from the source that was just replaced is ignored" do
      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, AnotherCommander, @manager),
          throttle_state()
        )

      {:noreply, state} =
        Throttle.handle_info(
          source_message(:requested_throttle, D.new("1.0"), @commander),
          state
        )

      refute D.equal?(state.requested_throttle, D.new("1.0")),
             "a commander that lost the selection still moved the vehicle"
    end
  end

  describe "source authority" do
    test "only the configured manager can change the source" do
      # Anything else naming a source is either a misconfiguration or
      # something impersonating the manager. Either way it must not be
      # able to hand itself the vehicle.
      state = throttle_state()

      {:noreply, unchanged} =
        Throttle.handle_info(
          source_message(:requested_throttle_source, Impostor, NotTheManager),
          state
        )

      assert unchanged.requested_throttle_source == @commander
    end
  end
end
