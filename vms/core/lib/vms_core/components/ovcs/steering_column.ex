defmodule VmsCore.Components.OVCS.SteeringColumn do
  @moduledoc """
    OVCS custom steering column using a stepper motor, generic controller and modified VW steering column
  """
  use GenServer
  alias VmsCore.Components.OVCS.GenericController
  alias VmsCore.{Bus, PID}
  alias Cantastic.{Frame, Receiver, Signal, Emitter}
  alias Decimal, as: D
  require Logger

  @zero D.new(0)
  @loop_period 10
  @frequency_range 65535 # in theory 200000 to match the 2.5micro seconds mimimal pulse width, but the CAN signal is limited to 65535
  @duty_cycle_percentage D.new("0.5")
  @direction_mapping %{clockwise: true, counter_clockwise: false}

  @kp D.new("0.04")
  @ki D.new("0.01")
  @kd D.new("0")
  @minimum_steering_angle D.new("-400")
  @maximum_steering_angle D.new("400")

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    power_relay_controller: power_relay_controller,
    power_relay_pin: power_relay_pin,
    actuation_controller: actuation_controller,
    direction_pin: direction_pin,
    external_pwm_id: external_pwm_id})
  do
    :ok = Emitter.configure(:misc, "lws_config", %{
      parameters_builder_function: :default,
      initial_data: %{
        "command" => "reset_angle_calibration_status",
      }
    })
    :ok = Receiver.subscribe(self(), :misc, ["lws_status"])
    {:ok, timer} = :timer.send_interval(@loop_period, :loop)
    {:ok, %{
      loop_timer: timer,
      angle: @zero,
      angular_speed: @zero,
      trimming_valid: false,
      calibration_valid: false,
      sensor_ready: false,
      power_relay_controller: power_relay_controller,
      actuation_controller: actuation_controller,
      power_relay_pin: power_relay_pin,
      direction_pin: direction_pin,
      external_pwm_id: external_pwm_id,
      emitted_frequency: nil,
      emitted_direction: nil,
      pid: nil,
      automatic_mode_enabled: false,
      enable_automatic_mode: false,
      desired_angle: @zero,
      target_motor_speed_percentage: @zero,
      kp: @zero,
      kd: @zero,
      ki: @zero
    }}
  end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_automatic_mode()
      |> actuate()
      |> emit_metrics()
    {:noreply, state}
  end

  def handle_info({:handle_frame, %Frame{signals: signals}}, state) do
    %{
      "steering_wheel_angle" => %Signal{value: angle},
      "steering_wheel_angular_speed" => %Signal{value: angular_speed},
      "steering_wheel_trimming_valid" => %Signal{value: trimming_valid},
      "steering_wheel_calibration_valid" => %Signal{value: calibration_valid},
      "steering_wheel_sensor_ready" => %Signal{value: sensor_ready}
    } = signals
    {:noreply, %{
      state |
        angle: 0 |> D.sub(angle),
        angular_speed: angular_speed,
        trimming_valid: trimming_valid,
        calibration_valid: calibration_valid,
        sensor_ready: sensor_ready
      }
    }
  end

  defp toggle_automatic_mode(state) do
    cond do
      state.enable_automatic_mode && !state.automatic_mode_enabled ->
        pid = init_pid(state)
        :ok = GenericController.set_digital_value(state.power_relay_controller, state.power_relay_pin, true)
        %{state | pid: pid, automatic_mode_enabled: true}
      !state.enable_automatic_mode && state.automatic_mode_enabled ->
        :ok = GenericController.set_digital_value(state.power_relay_controller, state.power_relay_pin, false)
        %{state | automatic_mode_enabled: false}
      true ->
        state
    end
  end

  defp actuate(state) do
    case state.automatic_mode_enabled do
      true ->
        if state.angle |> D.lt?(@maximum_steering_angle) && state.angle |> D.gt?(@minimum_steering_angle) do
          pid = PID.iterate(state.pid, state.angle, state.desired_angle)
          target_motor_speed_percentage = pid.output
          state = %{state | pid: pid, target_motor_speed_percentage: target_motor_speed_percentage}

          direction = case target_motor_speed_percentage |> D.lt?(0) do
            true -> :counter_clockwise
            false -> :clockwise
          end
          state = case state.emitted_direction == direction  do
            true -> state
            false ->
              :ok = GenericController.set_digital_value(state.actuation_controller, state.direction_pin,  @direction_mapping[direction])
              %{state | emitted_direction: direction}
          end

          frequency = target_motor_speed_percentage
            |> D.abs()
            |> D.mult(@frequency_range)

          state = case state.emitted_frequency == frequency  do
            true -> state
            false ->
              enabled = frequency |> D.gt?(0)
              :ok = GenericController.set_external_pwm(state.actuation_controller, state.external_pwm_id, enabled, @duty_cycle_percentage, frequency)
              %{state | emitted_frequency: frequency}
          end
          state
        else
          Logger.error("ALERT DEACTVATION")
          %{state | enable_automatic_mode: false}
        end
      false -> state
    end
  end

  defp init_pid(state) do
    PID.new(
      kp: state.kp,
      ki: state.ki,
      kd: state.kd,
      reset_derivative_when_setpoint_changes: true
    )
  end

  @impl true
  def handle_call({:test_set_angle, %{angle: angle, kp: kp, kd: kd, ki: ki}}, _from, state) do
    {:reply, :ok, %{state | enable_automatic_mode: true, desired_angle: angle, kp: kp, kd: kd, ki: ki}}
  end
  def handle_call(:deactivate, _from, state) do
    {:reply, :ok, %{state | enable_automatic_mode: false, target_motor_speed_percentage: @zero}}
  end

  def test_set_angle(%{angle: _angle, kp: _kp, kd: _kd, ki: _ki} = params) do
    #TODO set min/max
    GenServer.call(__MODULE__, {:test_set_angle, params})
  end

  def deactivate do
    GenServer.call(__MODULE__, :deactivate)
  end

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :angle, value: state.angle, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :angular_speed, value: state.angular_speed, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :trimming_valid, value: state.trimming_valid, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :calibration_valid, value: state.calibration_valid, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :sensor_ready, value: state.sensor_ready, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :desired_angle, value: state.desired_angle, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :target_motor_speed_percentage, value: state.target_motor_speed_percentage, source: __MODULE__})
    state
  end

  def calibrate_angle_0 do
    :ok = reset_angle_calibration_status()
    :timer.sleep(500)
    :ok = set_sensor_0()
  end

  defp reset_angle_calibration_status do
    :ok = Emitter.update(:misc, "lws_config", fn (data) ->
      %{data | "command" => "reset_angle_calibration_status"}
    end)
    :ok = Emitter.enable(:misc, "lws_config")
    :timer.sleep(500)
    :ok = Emitter.disable(:misc, "lws_config")
  end

  defp set_sensor_0 do
    :ok = Emitter.update(:misc, "lws_config", fn (data) ->
      %{data | "command" => "set_angle_zero"}
    end)
    :ok = Emitter.enable(:misc, "lws_config")
    :timer.sleep(500)
    :ok = Emitter.disable(:misc, "lws_config")
  end
end
