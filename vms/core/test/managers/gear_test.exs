defmodule VmsCore.Managers.GearTest do
  use ExUnit.Case, async: true

  alias OvcsBus.Message
  alias VmsCore.Managers.Gear

  # Source identifiers. The manager gates every inbound message on the
  # source field matching one of the configured sources; we exercise
  # that gating here via the handle_info/2 callback directly.
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

      {:noreply, result} =
        Gear.handle_info(
          %Message{name: :requested_gear, value: :drive, source: Rogue},
          state
        )

      assert result == state
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

  test "an unrelated Bus.Message is dropped without changing state" do
    original = stub_state()

    {:noreply, result} =
      Gear.handle_info(
        %Message{name: :something_unrelated, value: 123, source: Someone},
        original
      )

    assert result == original
  end
end
