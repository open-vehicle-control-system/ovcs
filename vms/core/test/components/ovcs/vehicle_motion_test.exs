defmodule VmsCore.Components.OVCS.VehicleMotionTest do
  @moduledoc """
  The motion frame's three claims: the sign follows the command, the
  magnitude follows the sensor, and an unknown speed is flagged rather
  than encoded as a standstill.

  Driven through `handle_info/2` against a stub state, the way the
  actuator tests do — `init/1` configures a CAN emitter, which is not
  under test.
  """
  use ExUnit.Case, async: true

  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.OVCS.VehicleMotion

  @manager ControlLevelManager
  @sensor SpeedSensor
  @commander SomeCommander

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        speed_source: @sensor,
        selected_control_level_source: @manager,
        steering_factor: D.from_float(0.52),
        requested_throttle_source: @commander,
        requested_steering_source: @commander,
        direction_sign: 1,
        requested_steering: D.new(0),
        speed: nil,
        sequence: 0
      },
      overrides
    )
  end

  describe "the direction sign" do
    test "follows the sign of the selected throttle request" do
      assert VehicleMotion.direction_sign(D.new("0.4"), -1) == 1
      assert VehicleMotion.direction_sign(D.new("-0.4"), 1) == -1
    end

    test "a zero throttle keeps the last sign: coasting is not a direction change" do
      assert VehicleMotion.direction_sign(D.new(0), -1) == -1
      assert VehicleMotion.direction_sign(D.new(0), 1) == 1
    end

    test "only the selected commander moves it" do
      {:noreply, unchanged} =
        VehicleMotion.handle_info(
          %Message{name: :requested_throttle, value: D.new("-1"), source: Impostor},
          state()
        )

      assert unchanged.direction_sign == 1
    end
  end

  describe "the speed" do
    test "converts km/h to signed m/s" do
      # 3.6 km/h is 1 m/s.
      assert D.eq?(VehicleMotion.signed_speed_m_s(D.new("3.6"), 1), D.new("1.000"))
      assert D.eq?(VehicleMotion.signed_speed_m_s(D.new("3.6"), -1), D.new("-1.000"))
    end

    test "nil encodes as zero, and speed_valid is what says not to read it" do
      assert D.eq?(VehicleMotion.signed_speed_m_s(nil, -1), D.new(0))
    end

    test "the sequence advances on a fresh sample and holds on nil" do
      {:noreply, state} =
        VehicleMotion.handle_info(
          %Message{name: :speed, value: D.new("1.24"), source: @sensor},
          state()
        )

      assert state.sequence == 1
      assert D.eq?(state.speed, D.new("1.24"))

      {:noreply, state} =
        VehicleMotion.handle_info(%Message{name: :speed, value: nil, source: @sensor}, state)

      assert state.sequence == 1
      assert state.speed == nil
    end

    test "the sequence wraps at 255" do
      {:noreply, state} =
        VehicleMotion.handle_info(
          %Message{name: :speed, value: D.new(0), source: @sensor},
          state(%{sequence: 255})
        )

      assert state.sequence == 0
    end
  end

  describe "the steering angle" do
    test "scales the normalised request by the steering limit" do
      assert D.eq?(
               VehicleMotion.steering_angle(D.new("0.5"), D.from_float(0.52)),
               D.new("0.260")
             )
    end

    test "a negative steering_sign flips the reported angle back to REP-103" do
      factor = D.mult(D.from_float(0.52), -1)
      assert D.eq?(VehicleMotion.steering_angle(D.new("0.5"), factor), D.new("-0.260"))
    end

    test "only the selected commander moves the request" do
      {:noreply, unchanged} =
        VehicleMotion.handle_info(
          %Message{name: :requested_steering, value: D.new("1"), source: Impostor},
          state()
        )

      assert D.eq?(unchanged.requested_steering, D.new(0))
    end
  end

  describe "following the manager" do
    test "adopts the sources the manager names, from the manager only" do
      {:noreply, state} =
        VehicleMotion.handle_info(
          %Message{name: :requested_throttle_source, value: NewCommander, source: @manager},
          state()
        )

      assert state.requested_throttle_source == NewCommander

      {:noreply, unchanged} =
        VehicleMotion.handle_info(
          %Message{name: :requested_steering_source, value: Impostor, source: NotTheManager},
          state()
        )

      assert unchanged.requested_steering_source == @commander
    end
  end
end
