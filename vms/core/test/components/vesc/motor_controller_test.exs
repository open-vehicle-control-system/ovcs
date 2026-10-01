defmodule VmsCore.Components.Vesc.MotorControllerTest do
  @moduledoc """
  The VESC motor controller's claims: one command frame per kind of
  commander, the release when nothing commands, a zero velocity that
  brakes from any motor state, the same source-following as the PWM
  actuators, and telemetry published once per frame and withdrawn when
  the frame dies.

  Driven through `handle_info/2` and the pure conversions against a
  stub state, the way the Traxxas tests do — `init/1` configures CAN
  emitters and frame watchers, neither of which is under test.
  """
  use ExUnit.Case, async: true

  alias Cantastic.{Frame, Signal}
  alias Decimal, as: D
  alias OvcsBus.Message
  alias VmsCore.Components.Vesc.MotorController

  @manager ControlLevelManager
  @hand SomeRadioThrottle
  @planner PlannerVelocity
  @vesc Vms.Vesc

  # A 4-pole motor, 984 motor rpm at a full linear request.
  @pole_pairs 2
  @max_rpm 984

  defp state(overrides \\ %{}) do
    Map.merge(
      %{
        loop_timer: nil,
        process_name: @vesc,
        network: :misc,
        frames: MotorController.frame_names(@vesc),
        selected_control_level_source: @manager,
        linear_sources: [@planner],
        caps: MotorController.caps(%{}),
        erpm_per_request: MotorController.erpm_per_request(@max_rpm, @pole_pairs),
        pole_pairs: @pole_pairs,
        noise_rpm: D.new(5),
        rotation_from: :tachometer,
        tachometer_samples: [],
        requested_throttle_source: @hand,
        requested_throttle: D.new("0.6"),
        command: nil
      },
      overrides
    )
  end

  defp planner(requested),
    do: state(%{requested_throttle_source: @planner, requested_throttle: D.new(requested)})

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

  describe "frame names" do
    test "follow the process name, the way the generic controller's do" do
      assert MotorController.frame_names(Vms.Vesc) == %{
               set_duty: "vesc_set_duty",
               set_current: "vesc_set_current",
               set_current_brake: "vesc_set_current_brake",
               set_rpm: "vesc_set_rpm",
               status: "vesc_status",
               status_5: "vesc_status_5"
             }

      assert MotorController.frame_names(Vms.RearMotor).status == "rear_motor_status"
    end
  end

  describe "direction" do
    test "the sign of the rotation, with a stray rpm at rest reading as stopped" do
      noise = D.new(5)
      assert MotorController.direction(D.new("450.0"), noise) == "forward"
      assert MotorController.direction(D.new("-450.0"), noise) == "backward"
      assert MotorController.direction(D.new("-1.0"), noise) == "stopped"
      assert MotorController.direction(D.new("5.0"), noise) == "stopped"
    end
  end

  describe "which command frame" do
    test "a hand's request is the duty, already shaped upstream, and the dashboard sees it" do
      {:set_duty, %{"duty" => duty}, throttle} = MotorController.command(state())
      # No caps: the request is applied as is.
      assert D.eq?(duty, D.new("0.6"))
      assert D.eq?(throttle, duty)
    end

    test "the caps scale a hand's duty, reverse following forward unless given" do
      capped = %{
        requested_throttle: D.new("0.5"),
        caps: MotorController.caps(%{max_throttle: D.new("0.1")})
      }

      {:set_duty, %{"duty" => forward}, _} = MotorController.command(state(capped))
      assert D.eq?(forward, D.new("0.05"))

      {:set_duty, %{"duty" => reverse}, _} =
        MotorController.command(state(%{capped | requested_throttle: D.new("-1")}))

      assert D.eq?(reverse, D.new("-0.1"))

      assert_raise ArgumentError, fn ->
        MotorController.caps(%{max_reverse: D.new("1.5")})
      end
    end

    test "a physical velocity drives the rpm, as a fraction of the maximum" do
      {:set_rpm, %{"erpm" => erpm}, throttle} = MotorController.command(planner(1))
      # Two pole pairs: twice the mechanical rpm.
      assert erpm == 1968
      assert D.eq?(throttle, D.new(1))
    end

    test "a negative velocity is a negative rpm: the planner may reverse" do
      {:set_rpm, %{"erpm" => erpm}, _} = MotorController.command(planner("-0.5"))
      assert erpm == -984
    end

    test "a velocity beyond the range is clamped, not extrapolated" do
      {:set_rpm, %{"erpm" => full}, _} = MotorController.command(planner(1))
      {:set_rpm, %{"erpm" => over}, throttle} = MotorController.command(planner(3))
      assert full == over
      assert D.eq?(throttle, D.new(1))
    end

    test "a zero velocity brakes with zero duty, not with zero rpm" do
      # A zero rpm setpoint does nothing to a released motor: the VESC
      # only starts its speed loop above its minimum erpm. Zero duty
      # brakes whatever state the motor is in.
      assert MotorController.command(planner(0)) == {:set_duty, %{"duty" => D.new(0)}, D.new(0)}
    end

    test "no source releases the motor: zero current, not zero rpm" do
      # A level that commands nothing must leave the motor free, the
      # way an unpowered ESC would.
      assert MotorController.command(state(%{requested_throttle_source: nil})) ==
               {:set_current, %{"current" => D.new(0)}, D.new(0)}
    end
  end

  describe "with gears" do
    @gear Gear

    defp geared(requested, gear) do
      state(%{
        selected_gear_source: @gear,
        selected_gear: gear,
        max_brake_current: D.new(20),
        caps: MotorController.caps(%{max_throttle: D.new("0.1"), max_reverse: D.new("0.05")}),
        requested_throttle: D.new(requested)
      })
    end

    test "a positive request drives forward in drive, capped by the forward cap" do
      {:set_duty, %{"duty" => duty}, throttle} = MotorController.command(geared(1, :drive))
      assert D.eq?(duty, D.new("0.1"))
      assert D.eq?(throttle, duty)
    end

    test "a positive request drives backward in reverse, capped by the reverse cap" do
      {:set_duty, %{"duty" => duty}, throttle} = MotorController.command(geared(1, :reverse))
      assert D.eq?(duty, D.new("-0.05"))
      assert D.eq?(throttle, duty)
    end

    test "a negative request brakes in every gear and never reverses" do
      for gear <- [:drive, :reverse, :neutral, :parking, nil] do
        assert {:set_current_brake, %{"current" => current}, throttle} =
                 MotorController.command(geared(-1, gear))

        assert D.eq?(current, D.new(20))
        assert D.eq?(throttle, D.new(0))
      end
    end

    test "the brake current is proportional to the request" do
      {:set_current_brake, %{"current" => current}, _} =
        MotorController.command(geared("-0.5", :drive))

      assert D.eq?(current, D.new(10))
    end

    test "a released trigger coasts, in drive as in reverse" do
      # The hand's curve turns a drifting trigger into exactly zero.
      for gear <- [:drive, :reverse] do
        requested = "0"

        assert MotorController.command(geared(requested, gear)) ==
                 {:set_current, %{"current" => D.new(0)}, D.new(0)}
      end
    end

    test "neutral, parking and an unknown gear release a positive request" do
      for gear <- [:neutral, :parking, nil] do
        assert MotorController.command(geared(1, gear)) ==
                 {:set_current, %{"current" => D.new(0)}, D.new(0)}
      end
    end

    test "a velocity ignores the gear: its sign is the direction of travel" do
      state =
        geared("-0.5", :drive)
        |> Map.put(:requested_throttle_source, @planner)

      assert {:set_rpm, %{"erpm" => -984}, _} = MotorController.command(state)
    end

    test "only the gear source's gear is taken" do
      {:noreply, state} =
        MotorController.handle_info(
          source_message(:selected_gear, :reverse, @gear),
          geared(1, nil)
        )

      assert state.selected_gear == :reverse

      {:noreply, unchanged} =
        MotorController.handle_info(source_message(:selected_gear, :drive, Impostor), state)

      assert unchanged.selected_gear == :reverse
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
      {:set_duty, _, _} = MotorController.command(state())

      {:noreply, state} =
        MotorController.handle_info(
          source_message(:requested_throttle_source, @planner, @manager),
          state()
        )

      {:set_rpm, _, _} = MotorController.command(state)
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
    setup do
      OvcsBus.subscribe("messages")
      :ok
    end

    test "from the erpm, each status frame is one rotation and one current message, sign kept" do
      state = state(%{rotation_from: :erpm})

      {:noreply, state} =
        MotorController.handle_info({:handle_frame, status_frame(1968, D.new("3.5"))}, state)

      assert_received %Message{name: :rotation_per_minute, value: rpm, source: @vesc}
      assert D.eq?(rpm, D.new("984.0"))
      assert_received %Message{name: :motor_current, value: current, source: @vesc}
      assert D.eq?(current, D.new("3.5"))

      {:noreply, _} =
        MotorController.handle_info({:handle_frame, status_frame(-984, D.new("-3.5"))}, state)

      assert_received %Message{name: :rotation_per_minute, value: rpm, source: @vesc}
      assert D.eq?(rpm, D.new("-492.0"))
      assert_received %Message{name: :direction, value: "backward", source: @vesc}
    end

    test "from the tachometer, the status frame carries the current but no rotation" do
      {:noreply, _} =
        MotorController.handle_info({:handle_frame, status_frame(1968, D.new("3.5"))}, state())

      assert_received %Message{name: :motor_current, source: @vesc}
      refute_received %Message{name: :rotation_per_minute, source: @vesc}
    end

    test "a dead frame withdraws the rotation only when it is the rotation's source" do
      # Silence is not standstill: the manager must refuse mode changes
      # rather than read a dead VESC as a stopped vehicle.
      {:noreply, _} =
        MotorController.handle_info(
          {:handle_missing_frame, :misc, "vesc_status"},
          state(%{rotation_from: :erpm})
        )

      assert_received %Message{name: :rotation_per_minute, value: nil, source: @vesc}
      assert_received %Message{name: :motor_current, value: nil, source: @vesc}

      {:noreply, _} =
        MotorController.handle_info({:handle_missing_frame, :misc, "vesc_status"}, state())

      refute_received %Message{name: :rotation_per_minute, source: @vesc}

      {:noreply, state} =
        MotorController.handle_info(
          {:handle_missing_frame, :misc, "vesc_status_5"},
          state(%{tachometer_samples: [{0, 12}]})
        )

      assert_received %Message{name: :rotation_per_minute, value: nil, source: @vesc}
      assert state.tachometer_samples == []
    end

    test "the tachometer rate is steps over 6 per electrical turn, signed, over the window" do
      # 2 pole pairs: 12 steps a motor turn. 24 steps in 100 ms is 1200 rpm.
      {nil, samples} = MotorController.tachometer_rotation([], {1000, 500}, @pole_pairs)
      {rpm, samples} = MotorController.tachometer_rotation(samples, {1100, 524}, @pole_pairs)
      assert D.eq?(rpm, D.new("1200.0"))

      {rpm, _} = MotorController.tachometer_rotation(samples, {1200, 500}, @pole_pairs)
      assert D.eq?(rpm, D.new("0.0"))

      {rpm, _} = MotorController.tachometer_rotation([{1000, 500}], {1100, 488}, @pole_pairs)
      assert D.eq?(rpm, D.new("-600.0"))
    end

    test "samples older than the window are dropped, and a lone sample gives no rate" do
      {rpm, samples} =
        MotorController.tachometer_rotation([{1000, 0}], {1300, 12}, @pole_pairs)

      assert rpm == nil
      assert samples == [{1300, 12}]
    end

    test "the input voltage comes from status 5 and dies with it" do
      frame = %Frame{
        name: "vesc_status_5",
        signals: %{
          "tachometer" => %Signal{name: "tachometer", value: 1200},
          "input_voltage" => %Signal{name: "input_voltage", value: D.new("15.8")}
        }
      }

      {:noreply, _} = MotorController.handle_info({:handle_frame, frame}, state())
      assert_received %Message{name: :input_voltage, value: voltage, source: @vesc}
      assert D.eq?(voltage, D.new("15.8"))

      {:noreply, _} =
        MotorController.handle_info({:handle_missing_frame, :misc, "vesc_status_5"}, state())

      assert_received %Message{name: :input_voltage, value: nil, source: @vesc}
    end

    test "a missing frame on another network is not this VESC's" do
      {:noreply, _} =
        MotorController.handle_info({:handle_missing_frame, :ovcs, "vesc_status"}, state())

      refute_received %Message{name: :rotation_per_minute, source: @vesc}
    end
  end

  test "two VESCs are two children, each named by its process name" do
    specs =
      [Vms.FrontVesc, Vms.RearVesc]
      |> Enum.map(&Supervisor.child_spec({MotorController, %{process_name: &1}}, []))

    assert Enum.map(specs, & &1.id) == [Vms.FrontVesc, Vms.RearVesc]

    assert %{start: {MotorController, :start_link, [%{process_name: Vms.FrontVesc}]}} =
             hd(specs)
  end
end
