defmodule VmsCore.Components.Vesc.MotorControllerTest do
  @moduledoc """
  The VESC motor controller's claims: one command frame per kind of commander,
  the release when nothing commands, the same source-following as the
  PWM actuators, and telemetry that is nil until the VESC reports and
  nil again when it stops.

  Driven through `handle_info/2` and the pure conversions against a
  stub state, the way the Traxxas tests do — `init/1` configures CAN
  emitters and a frame watcher, neither of which is under test.
  """
  use ExUnit.Case, async: true

  alias Cantastic.{Frame, Signal}
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.Traxxas.Throttle
  alias VmsCore.Components.Vesc.MotorController

  @manager ControlLevelManager
  @hand SomeRadioThrottle
  @planner PlannerVelocity

  # An AXE540 (2 pole pairs) at 984 motor rpm for a full request: what
  # 0.5 m/s comes to through a 13/54 pinion, the Slash 4x4
  # transmission's 2.72 and 54.8 mm wheels.
  @pole_pairs 2
  @max_rpm 984

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        selected_control_level_source: @manager,
        linear_sources: [@planner],
        curve: Throttle.curve(%{}),
        erpm_per_request: MotorController.erpm_per_request(@max_rpm, @pole_pairs),
        pole_pairs: @pole_pairs,
        requested_throttle_source: @hand,
        requested_throttle: D.new("0.6"),
        command: nil,
        erpm: nil,
        motor_current: nil,
        input_voltage: nil
      },
      overrides
    )
  end

  defp source_message(name, value, source), do: %Message{name: name, value: value, source: source}

  defp status_frame(erpm, current) do
    %Frame{
      name: "vesc_status",
      signals: %{
        "erpm" => %Signal{name: "erpm", value: erpm},
        "motor_current" => %Signal{name: "motor_current", value: current},
        "duty" => %Signal{name: "duty", value: D.new("0.1")}
      }
    }
  end

  describe "which command frame" do
    test "a hand drives the duty, shaped by the curve" do
      {"vesc_set_duty", %{"duty" => duty}} = MotorController.command(state())
      # The default curve is the full square.
      assert D.eq?(duty, D.new("0.36"))
    end

    test "a physical velocity drives the rpm, as a fraction of the maximum" do
      {"vesc_set_rpm", %{"erpm" => erpm}} =
        MotorController.command(
          state(%{requested_throttle_source: @planner, requested_throttle: D.new(1)})
        )

      # Two pole pairs: twice the mechanical rpm.
      assert erpm == 1968
    end

    test "a negative velocity is a negative rpm: the planner may reverse" do
      {"vesc_set_rpm", %{"erpm" => erpm}} =
        MotorController.command(
          state(%{requested_throttle_source: @planner, requested_throttle: D.new("-0.5")})
        )

      assert erpm == -984
    end

    test "a velocity beyond the range is clamped, not extrapolated" do
      {"vesc_set_rpm", %{"erpm" => full}} =
        MotorController.command(
          state(%{requested_throttle_source: @planner, requested_throttle: D.new(1)})
        )

      {"vesc_set_rpm", %{"erpm" => over}} =
        MotorController.command(
          state(%{requested_throttle_source: @planner, requested_throttle: D.new(3)})
        )

      assert full == over
    end

    test "no source releases the motor: zero current, not zero rpm" do
      # Zero rpm brakes to a standstill. A level that commands nothing
      # must leave the motor free, the way an unpowered ESC would.
      assert MotorController.command(state(%{requested_throttle_source: nil})) ==
               {"vesc_set_current", %{"current" => D.new(0)}}
    end
  end

  describe "a level that commands nothing" do
    test "zeroes the request rather than holding it" do
      {:noreply, state} =
        MotorController.handle_info(
          source_message(:requested_throttle_source, nil, @manager),
          state()
        )

      assert D.eq?(state.requested_throttle, D.new(0))
      assert state.requested_throttle_source == nil
    end
  end

  describe "switching between commanders" do
    test "the new source is adopted and the current request is kept" do
      {:noreply, state} =
        MotorController.handle_info(
          source_message(:requested_throttle_source, @planner, @manager),
          state()
        )

      assert state.requested_throttle_source == @planner
      assert D.eq?(state.requested_throttle, D.new("0.6"))
    end

    test "the same request changes frame with its source" do
      # A switch from a hand to a planner at an unchanged request is a
      # different command: a cache keyed on the request alone would
      # leave the VESC in duty mode.
      hand = MotorController.command(state())

      {:noreply, state} =
        MotorController.handle_info(
          source_message(:requested_throttle_source, @planner, @manager),
          state()
        )

      planner = MotorController.command(state)
      assert elem(hand, 0) == "vesc_set_duty"
      assert elem(planner, 0) == "vesc_set_rpm"
    end

    test "a request from the source that was just replaced is ignored" do
      {:noreply, state} =
        MotorController.handle_info(
          source_message(:requested_throttle_source, @planner, @manager),
          state()
        )

      {:noreply, state} =
        MotorController.handle_info(
          source_message(:requested_throttle, D.new("1.0"), @hand),
          state
        )

      refute D.eq?(state.requested_throttle, D.new("1.0")),
             "a commander that lost the selection still moved the vehicle"
    end

    test "only the configured manager can change the source" do
      {:noreply, unchanged} =
        MotorController.handle_info(
          source_message(:requested_throttle_source, Impostor, NotTheManager),
          state()
        )

      assert unchanged.requested_throttle_source == @hand
    end
  end

  describe "telemetry from the status frames" do
    test "is unknown until the VESC reports" do
      assert MotorController.rotation_per_minute(nil, @pole_pairs) == nil
    end

    test "the motor rpm is the electrical rpm through the pole pairs, sign kept" do
      {:noreply, state} =
        MotorController.handle_info({:handle_frame, status_frame(1968, D.new("3.5"))}, state())

      assert D.eq?(
               MotorController.rotation_per_minute(state.erpm, state.pole_pairs),
               D.new("984.0")
             )

      assert D.eq?(state.motor_current, D.new("3.5"))

      {:noreply, state} =
        MotorController.handle_info({:handle_frame, status_frame(-984, D.new("-3.5"))}, state)

      assert D.eq?(
               MotorController.rotation_per_minute(state.erpm, state.pole_pairs),
               D.new("-492.0")
             )
    end

    test "goes back to unknown when the status frame stops arriving" do
      {:noreply, state} =
        MotorController.handle_info({:handle_frame, status_frame(0, D.new(0))}, state())

      assert state.erpm == 0

      {:noreply, state} =
        MotorController.handle_info({:handle_missing_frame, :ovcs, "vesc_status"}, state)

      assert state.erpm == nil
      assert state.motor_current == nil
    end

    test "the input voltage comes from status 5" do
      frame = %Frame{
        name: "vesc_status_5",
        signals: %{
          "tachometer" => %Signal{name: "tachometer", value: 1200},
          "input_voltage" => %Signal{name: "input_voltage", value: D.new("15.8")}
        }
      }

      {:noreply, state} = MotorController.handle_info({:handle_frame, frame}, state())
      assert D.eq?(state.input_voltage, D.new("15.8"))
    end
  end
end
