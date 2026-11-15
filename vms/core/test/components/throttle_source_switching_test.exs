defmodule VmsCore.Components.ThrottleSourceSwitchingTest do
  @moduledoc """
  Every consumer of a routed request stops acting on it when
  `Managers.ControlLevel` names no source for it: the inverter's
  `:requested_throttle`, the brake booster's `:requested_braking`.

  The request's handler gates on the source, so with a nil source no
  message matches and the last request would be held. Held in the
  inverter it is applied as torque every tick; held in the brake
  booster it keeps the automatic braking on. Each consumer therefore
  zeroes the request on the way to a level that commands nothing.

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

  @request_keys %{
    Inverter => :requested_throttle,
    IBoosterGen2 => :requested_braking
  }

  defp state(module) do
    %{
      :selected_control_level_source => @manager,
      @source_keys[module] => @commander,
      @request_keys[module] => D.new("0.6")
    }
  end

  defp source_message(module, value, source),
    do: %Message{name: @source_keys[module], value: value, source: source}

  for {module, source_key} <- @source_keys do
    describe "#{inspect(module)} on a level that commands nothing" do
      test "zeroes the request rather than holding it" do
        module = unquote(module)

        {:noreply, state} =
          module.handle_info(source_message(module, nil, @manager), state(module))

        assert state[unquote(source_key)] == nil

        assert D.eq?(state[@request_keys[module]], D.new(0)),
               "the last request survived a switch to a level with no commander"
      end

      test "keeps the request across a switch between commanders" do
        module = unquote(module)

        {:noreply, state} =
          module.handle_info(source_message(module, AnotherCommander, @manager), state(module))

        assert state[unquote(source_key)] == AnotherCommander
        assert D.eq?(state[@request_keys[module]], D.new("0.6"))
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
    defp booster do
      %{
        selected_control_level_source: @manager,
        requested_braking_source: @commander,
        requested_braking: D.new(0)
      }
    end

    defp braking_from(booster, value, source) do
      {:noreply, booster} =
        IBoosterGen2.handle_info(
          %Message{name: :requested_braking, value: D.new(value), source: source},
          booster
        )

      booster.requested_braking
    end

    test "comes from the braking source, not the throttle source" do
      {:noreply, booster} =
        IBoosterGen2.handle_info(
          %Message{name: :requested_throttle_source, value: Pedal, source: @manager},
          booster()
        )

      assert D.eq?(braking_from(booster, "0.4", @commander), D.new("0.4"))
    end

    test "ignores the braking another component requests, its own included" do
      for source <- [AnotherCommander, IBoosterGen2] do
        assert D.eq?(braking_from(booster(), "0.9", source), 0)
      end
    end

    test "ignores its braking source's throttle" do
      {:noreply, after_throttle} =
        IBoosterGen2.handle_info(
          %Message{name: :requested_throttle, value: D.new("-0.7"), source: @commander},
          booster()
        )

      assert after_throttle == booster()
    end

    test "holds a request outside [0, 1] to that range" do
      assert D.eq?(braking_from(booster(), "5", @commander), 1)
      assert D.eq?(braking_from(booster(), "-0.3", @commander), 0)
    end
  end
end
