defmodule VmsCore.Components.ThrottleSourceSwitchingTest do
  @moduledoc """
  Every consumer of `:requested_throttle` stops acting on it when
  `Managers.ControlLevel` names no source.

  The handler for `:requested_throttle` gates on the source, so with a
  nil source no message matches and the last request would be held.
  Held in the inverter it is applied as torque every tick; held in the
  brake booster a negative request keeps the automatic braking on. Each
  consumer therefore zeroes the request on the way to a level that
  commands nothing.

  Driven through `handle_info/2` against a stub state, the way
  `VmsCore.Managers.GearTest` does: the transition is the subject, not
  the CAN stack `init/1` would need.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.Bosch.IBoosterGen2
  alias VmsCore.Components.Nissan.LeafAZE0.Inverter

  @manager ControlLevelManager
  @commander SomeCommander

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        selected_control_level_source: @manager,
        requested_throttle_source: @commander,
        requested_throttle: D.new("0.6")
      },
      overrides
    )
  end

  defp source_message(value, source),
    do: %Message{name: :requested_throttle_source, value: value, source: source}

  for module <- [Inverter, IBoosterGen2] do
    describe "#{inspect(module)} on a level that commands nothing" do
      test "zeroes the throttle rather than holding it" do
        {:noreply, state} =
          unquote(module).handle_info(source_message(nil, @manager), state())

        assert state.requested_throttle_source == nil

        assert D.eq?(state.requested_throttle, D.new(0)),
               "the last throttle survived a switch to a level with no commander"
      end

      test "keeps the request across a switch between commanders" do
        {:noreply, state} =
          unquote(module).handle_info(source_message(AnotherCommander, @manager), state())

        assert state.requested_throttle_source == AnotherCommander
        assert D.eq?(state.requested_throttle, D.new("0.6"))
      end

      test "ignores a source named by anything but the manager" do
        original = state()

        {:noreply, state} =
          unquote(module).handle_info(source_message(Impostor, NotTheManager), original)

        assert state == original
      end
    end
  end
end
