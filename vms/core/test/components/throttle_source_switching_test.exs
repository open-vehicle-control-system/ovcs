defmodule VmsCore.Components.ThrottleSourceSwitchingTest do
  @moduledoc """
  Every consumer of `:requested_throttle` stops acting on it when
  `Managers.ControlLevel` names no source for it: the inverter's
  throttle source, the brake booster's braking source.

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

  @source_keys %{
    Inverter => :requested_throttle_source,
    IBoosterGen2 => :requested_braking_source
  }

  defp state(module) do
    %{
      :selected_control_level_source => @manager,
      @source_keys[module] => @commander,
      :requested_throttle => D.new("0.6")
    }
  end

  defp source_message(module, value, source),
    do: %Message{name: @source_keys[module], value: value, source: source}

  for {module, source_key} <- @source_keys do
    describe "#{inspect(module)} on a level that commands nothing" do
      test "zeroes the throttle rather than holding it" do
        module = unquote(module)

        {:noreply, state} =
          module.handle_info(source_message(module, nil, @manager), state(module))

        assert state[unquote(source_key)] == nil

        assert D.eq?(state.requested_throttle, D.new(0)),
               "the last throttle survived a switch to a level with no commander"
      end

      test "keeps the request across a switch between commanders" do
        module = unquote(module)

        {:noreply, state} =
          module.handle_info(source_message(module, AnotherCommander, @manager), state(module))

        assert state[unquote(source_key)] == AnotherCommander
        assert D.eq?(state.requested_throttle, D.new("0.6"))
      end

      test "ignores a source named by anything but the manager" do
        module = unquote(module)
        original = state(module)

        {:noreply, state} =
          module.handle_info(source_message(module, Impostor, NotTheManager), original)

        assert state == original
      end
    end
  end

  describe "IBoosterGen2's braking request" do
    test "comes from the braking source, not the throttle source" do
      booster = %{
        selected_control_level_source: @manager,
        requested_braking_source: @commander,
        requested_throttle: D.new(0)
      }

      {:noreply, booster} =
        IBoosterGen2.handle_info(
          %Message{name: :requested_throttle_source, value: Pedal, source: @manager},
          booster
        )

      {:noreply, booster} =
        IBoosterGen2.handle_info(
          %Message{name: :requested_throttle, value: D.new("-0.4"), source: @commander},
          booster
        )

      assert D.eq?(booster.requested_throttle, D.new("-0.4"))
    end
  end
end
