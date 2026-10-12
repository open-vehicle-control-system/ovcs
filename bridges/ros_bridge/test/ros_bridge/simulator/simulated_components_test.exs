defmodule RosBridge.Simulator.SimulatedComponentsTest do
  @moduledoc """
  The simulated components against the VMS components they invert:
  the frames the VMS components emit are fed in, and what the simulated
  ones report must read back
  through the same arithmetic the VMS applies, restated here because
  the bridge does not depend on `vms_core`.
  """
  use ExUnit.Case, async: true

  alias Cantastic.Signal
  alias RosBridge.Simulator.SimulatedComponents.OVCS.{GenericController, RadioControl}
  alias RosBridge.Simulator.SimulatedComponents.Traxxas.Steering
  alias RosBridge.Simulator.SimulatedComponents.Vesc.MotorController
  alias RosBridge.Simulator.Vehicle

  @dt 0.01
  @pole_pairs 2
  @ratio 11.82
  @wheel_radius 0.0522

  defp vehicle(speed),
    do: %Vehicle{
      wheelbase_m: 0.324,
      wheel_radius_m: @wheel_radius,
      speed_m_s: speed,
      measured_speed_m_s: speed
    }

  defp signals(values),
    do: Map.new(values, fn {name, value} -> {name, %Signal{name: name, value: value}} end)

  defp vesc do
    {state, _received, _emitted} =
      MotorController.init(pole_pairs: @pole_pairs, motor_to_wheel_ratio: @ratio, min_erpm: 300)

    state
  end

  defp motor_rpm(speed), do: speed / (2 * :math.pi() * @wheel_radius) * 60 * @ratio

  describe "Vesc.MotorController" do
    test "set_rpm sets its speed" do
      erpm = round(motor_rpm(0.5) * @pole_pairs)
      state = MotorController.handle_frame("vesc_set_rpm", signals(%{"erpm" => erpm}), vesc(), 0)

      [{:speed, speed}] = MotorController.actuations(state, vehicle(0.0), 10)
      assert_in_delta speed, 0.5, 0.001
    end

    test "a set_rpm under the minimum erpm brakes to a stop" do
      state = MotorController.handle_frame("vesc_set_rpm", signals(%{"erpm" => 200}), vesc(), 0)
      assert MotorController.actuations(state, vehicle(0.3), 10) == [{:speed, 0.0}]
    end

    test "the motor is released once commands stop for the timeout" do
      current = Decimal.new("8.0")

      state =
        MotorController.handle_frame(
          "vesc_set_current",
          signals(%{"current" => current}),
          vesc(),
          0
        )

      assert [{:acceleration, _}] = MotorController.actuations(state, vehicle(0.0), 500)
      assert MotorController.actuations(state, vehicle(0.0), 1_500) == []
    end

    test "the tachometer reads back as the motor's rotation through the VMS's arithmetic" do
      speed = 0.8
      steps = 20

      moving = %{
        vehicle(speed)
        | wheel_turns_step: speed * @dt / (2 * :math.pi() * @wheel_radius)
      }

      {state, _} =
        Enum.reduce(1..steps, {vesc(), []}, fn _, {state, _} ->
          MotorController.step(state, moving, @dt, 0)
        end)

      # `MotorController.revolutions/2`: six steps per electrical turn.
      revolutions = trunc(state.tachometer) / (6 * @pole_pairs)
      assert_in_delta revolutions, motor_rpm(speed) / 60 * steps * @dt, 0.1
    end

    test "the erpm reads back as the motor's rpm" do
      # `MotorController.rotation_per_minute/2`.
      rpm = MotorController.erpm(vesc(), vehicle(1.0)) / @pole_pairs
      assert_in_delta rpm, motor_rpm(1.0), 1.0
    end
  end

  describe "OVCS.GenericController" do
    test "the pulse frequency agrees with the VESC through the spur ratio" do
      spur_per_wheel = @ratio * 13 / 54

      {state, _, _} =
        GenericController.init(
          pulse: %{shaft_turns_per_wheel_turn: spur_per_wheel, pulses_per_revolution: 1}
        )

      speed = 1.0

      moving = %{
        vehicle(speed)
        | wheel_turns_step: speed * @dt / (2 * :math.pi() * @wheel_radius)
      }

      {_state, updates} =
        Enum.reduce(1..100, {state, []}, fn _, {state, _} ->
          GenericController.step(state, moving, @dt, 0)
        end)

      {_, _, pulse} = List.keyfind(updates, "main_controller_pulse_counter_status", 1)
      spur_rpm = Decimal.to_float(pulse["pulse_pin0_frequency"]) * 60
      assert_in_delta spur_rpm * 54 / 13, motor_rpm(speed), motor_rpm(speed) * 0.02
    end

    test "the alive counter steps once per alive frame, not per tick" do
      {state, _, _} = GenericController.init([])

      {_state, [{_, _, alive}]} =
        Enum.reduce(1..25, {state, []}, fn _, {state, _} ->
          GenericController.step(state, vehicle(0.0), @dt, 0)
        end)

      assert alive["counter"] == 2
    end

    test "no pulse frame without a pulse sensor" do
      {_, [], emitted} = GenericController.init([])
      refute List.keymember?(emitted, "main_controller_pulse_counter_status", 1)
    end
  end

  describe "Traxxas.Steering" do
    setup do
      {state, _, _} = Steering.init(steering_limit_rad: 0.52, neutral: 0.05)
      %{servo: state}
    end

    test "the trimmed centre drives straight", %{servo: servo} do
      assert_in_delta Steering.angle(0.15 + 0.05 * 0.05, servo), 0.0, 1.0e-9
    end

    test "a positive request steers right, a negative REP-103 angle", %{servo: servo} do
      assert Steering.angle(0.19, servo) < 0
      assert Steering.angle(0.11, servo) > 0
    end

    test "a disabled PWM holds the wheels", %{servo: servo} do
      turned = %{servo | angle: 0.2}
      frame = signals(%{"enabled" => false, "duty_cycle" => 0})

      assert Steering.handle_frame("main_controller_external_pwm0_request", frame, turned, 0) ==
               turned
    end
  end

  describe "OVCS.RadioControl" do
    test "the script waits for the VMS, then applies each step at its time" do
      {state, _, _} =
        RadioControl.init(
          channels: %{6 => 1000},
          steps: [{1_000, %{6 => 1500}}, {2_000, %{6 => 2000}}]
        )

      {state, [_, {_, _, waiting}]} = RadioControl.step(state, nil, @dt, 5_000)
      assert waiting["channel6"] == 1000

      state = RadioControl.handle_frame("vms_status", %{}, state, 10_000)
      state = RadioControl.handle_frame("vms_status", %{}, state, 10_900)
      {state, [_, {_, _, radio}]} = RadioControl.step(state, nil, @dt, 11_000)
      assert radio["channel6"] == 1500
      state = RadioControl.handle_frame("vms_status", %{}, state, 11_900)
      {_state, [_, {_, _, ros}]} = RadioControl.step(state, nil, @dt, 12_000)
      assert ros["channel6"] == 2000
    end

    test "a VMS that goes quiet rewinds the script to its start" do
      {state, _, _} = RadioControl.init(channels: %{6 => 1000}, steps: [{1_000, %{6 => 2000}}])
      state = RadioControl.handle_frame("vms_status", %{}, state, 0)

      {state, [_, {_, _, silent}]} = RadioControl.step(state, nil, @dt, 2_000)
      assert silent["channel6"] == 1000
      assert state.started_at_ms == nil
    end
  end
end
