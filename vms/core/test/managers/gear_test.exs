defmodule VmsCore.Managers.GearTest do
  @moduledoc """
  The gear manager's source gating, every inbound message acted on only
  when its source is the configured one, and the gear it chooses. Driven
  through `handle_info/2` and `next_gear/1` against a stub state.
  """
  use ExUnit.Case, async: true

  alias OvcsBus.Message
  alias VmsCore.Managers.Gear

  @control_level_source ControlLevelManager
  @ready_to_drive_source OvcsStatus
  @speed_source LeafInverter
  @contact_source IgnitionKey

  defp stub_state(overrides \\ %{}) do
    base = %{
      selected_gear: :parking,
      requested_gear: :parking,
      requested_throttle: Decimal.new(0),
      speed: Decimal.new(0),
      ready_to_drive: false,
      loop_timer: nil,
      selected_control_level_source: @control_level_source,
      requested_throttle_source: nil,
      requested_gear_source: nil,
      requested_direction_source: nil,
      ready_to_drive_source: @ready_to_drive_source,
      speed_source: @speed_source,
      contact_source: @contact_source,
      contact: nil
    }

    Map.merge(base, overrides)
  end

  describe "source-gated source-config messages" do
    test "records requested_gear_source only when published by the control-level manager" do
      {:noreply, state} =
        Gear.handle_info(
          %Message{name: :requested_gear_source, value: Driver, source: @control_level_source},
          stub_state()
        )

      assert state.requested_gear_source == Driver
    end

    test "ignores requested_gear_source from an unrelated source" do
      original = stub_state()

      {:noreply, state} =
        Gear.handle_info(
          %Message{name: :requested_gear_source, value: Spoofer, source: RandomModule},
          original
        )

      assert state == original
    end
  end

  describe "a level that commands no throttle" do
    test "zeroes the held request rather than gating gear changes on it" do
      # With a nil source no `:requested_throttle` message matches, so
      # a held positive request would refuse gear changes for ever.
      state =
        stub_state(%{
          requested_throttle_source: Driver,
          requested_throttle: Decimal.new("0.6")
        })

      {:noreply, state} =
        Gear.handle_info(
          %Message{
            name: :requested_throttle_source,
            value: nil,
            source: @control_level_source
          },
          state
        )

      assert state.requested_throttle_source == nil
      assert Decimal.eq?(state.requested_throttle, Decimal.new(0))
    end

    test "a switch between commanders keeps the request" do
      state =
        stub_state(%{
          requested_throttle_source: Driver,
          requested_throttle: Decimal.new("0.6")
        })

      {:noreply, state} =
        Gear.handle_info(
          %Message{
            name: :requested_throttle_source,
            value: AnotherDriver,
            source: @control_level_source
          },
          state
        )

      assert state.requested_throttle_source == AnotherDriver
      assert Decimal.eq?(state.requested_throttle, Decimal.new("0.6"))
    end
  end

  describe "requested_gear vs requested_direction" do
    test "requested_gear updates state when the gear-source path is active" do
      state = stub_state(%{requested_gear_source: Driver})

      {:noreply, state} =
        Gear.handle_info(
          %Message{name: :requested_gear, value: :drive, source: Driver},
          state
        )

      assert state.requested_gear == :drive
    end

    test "requested_gear is ignored when published by a source other than the configured one" do
      state = stub_state(%{requested_gear_source: Driver})

      {:noreply, unchanged} =
        Gear.handle_info(
          %Message{name: :requested_gear, value: :drive, source: Rogue},
          state
        )

      assert unchanged == state
    end

    test "requested_direction :forward maps to :drive" do
      state = stub_state(%{requested_direction_source: Joystick})

      {:noreply, state} =
        Gear.handle_info(
          %Message{name: :requested_direction, value: :forward, source: Joystick},
          state
        )

      assert state.requested_gear == :drive
    end

    test "requested_direction :backward maps to :reverse" do
      state = stub_state(%{requested_direction_source: Joystick})

      {:noreply, state} =
        Gear.handle_info(
          %Message{name: :requested_direction, value: :backward, source: Joystick},
          state
        )

      assert state.requested_gear == :reverse
    end
  end

  describe "sensor updates gated on configured sources" do
    test "speed updates only from the configured speed_source" do
      accepted_state = stub_state()

      {:noreply, state} =
        Gear.handle_info(
          %Message{name: :speed, value: Decimal.new("5.5"), source: @speed_source},
          accepted_state
        )

      assert Decimal.equal?(state.speed, Decimal.new("5.5"))

      {:noreply, unchanged} =
        Gear.handle_info(
          %Message{name: :speed, value: Decimal.new("99"), source: Impostor},
          accepted_state
        )

      assert unchanged == accepted_state
    end

    test "ready_to_drive updates only from the configured source" do
      {:noreply, state} =
        Gear.handle_info(
          %Message{name: :ready_to_drive, value: true, source: @ready_to_drive_source},
          stub_state()
        )

      assert state.ready_to_drive == true
    end

    test "contact updates only from the configured contact_source" do
      {:noreply, state} =
        Gear.handle_info(
          %Message{name: :contact, value: :on, source: @contact_source},
          stub_state()
        )

      assert state.contact == :on
    end
  end

  describe "next_gear/1" do
    defp driving(overrides) do
      stub_state(
        Map.merge(
          %{contact: :on, ready_to_drive: true, selected_gear: :reverse, requested_gear: :drive},
          overrides
        )
      )
    end

    test "engages the requested direction at standstill with the throttle released" do
      assert Gear.next_gear(driving(%{})) == :drive
    end

    test "drops to neutral when the opposite direction comes with the throttle held" do
      assert Gear.next_gear(driving(%{requested_throttle: Decimal.new("0.4")})) == :neutral
    end

    test "drops to neutral when the opposite direction comes while moving" do
      assert Gear.next_gear(driving(%{speed: Decimal.new("3")})) == :neutral
    end

    test "engages from neutral once the throttle is released at standstill" do
      held = driving(%{selected_gear: :neutral, requested_throttle: Decimal.new("0.4")})
      assert Gear.next_gear(held) == nil
      assert Gear.next_gear(%{held | requested_throttle: Decimal.new(0)}) == :drive
    end

    test "keeps the gear the request already has" do
      assert Gear.next_gear(driving(%{selected_gear: :drive})) == nil
    end
  end

  test "an unrelated bus message is dropped without changing state" do
    original = stub_state()

    {:noreply, unchanged} =
      Gear.handle_info(
        %Message{name: :something_unrelated, value: 123, source: Someone},
        original
      )

    assert unchanged == original
  end
end
