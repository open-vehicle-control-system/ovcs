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

  @kp Decimal.new("0.08")
  @ki D.new(0) #Decimal.new("0.04")
  @kd D.new(0) #Decimal.new("0.005")
  @steering_angle_range D.new(400)
  @minimum_steering_angle D.new(-420)
  @maximum_steering_angle D.new(420)

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl true
  def init(%{
    requested_steering_source: requested_steering_source,
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
    Bus.subscribe("messages")
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
      requested_steering_source: requested_steering_source,
      requested_steering: @zero,
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
      kp: @kp,
      ki: @ki,
      kd: @kd
    }}
end

  @impl true
  def handle_info(:loop, state) do
    state = state
      |> toggle_automatic_mode()
      |> safety_deactivation()
      |> set_desired_angle()
      |> set_motor_speed_percentage()
      |> set_motor_direction()
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

  def handle_info(%Bus.Message{name: :requested_steering, value: requested_steering, source: source}, state) when source == state.requested_steering_source do
    {:noreply, %{state | requested_steering: requested_steering}}
  end
  def handle_info(%Bus.Message{}, state) do # TODO, replace Bus ?
    {:noreply, state}
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

  defp safety_deactivation(state) when state.automatic_mode_enabled == true do
    if state.angle |> D.lt?(@maximum_steering_angle) && state.angle |> D.gt?(@minimum_steering_angle) do
      state
    else
      Logger.error("ALERT DEACTVATION")
      %{state | enable_automatic_mode: false}
    end
  end
  defp safety_deactivation(state), do: state

  defp set_desired_angle(state) when state.automatic_mode_enabled == true do
    desired_angle = state.requested_steering |> D.mult(@steering_angle_range)
    %{state | desired_angle: desired_angle}
  end
  defp set_desired_angle(state), do: state

  defp set_motor_speed_percentage(state) when state.automatic_mode_enabled == true do
    pid = PID.iterate(state.pid, state.angle, state.desired_angle)
    target_motor_speed_percentage = pid.output
    %{state | pid: pid, target_motor_speed_percentage: target_motor_speed_percentage}
  end
  defp set_motor_speed_percentage(state), do: state

  defp set_motor_direction(state) when state.automatic_mode_enabled == true do
    direction = case state.target_motor_speed_percentage |> D.lt?(0) do
      true -> :counter_clockwise
      false -> :clockwise
    end

    case state.emitted_direction == direction  do
      true -> state
      false ->
        :ok = GenericController.set_digital_value(state.actuation_controller, state.direction_pin,  @direction_mapping[direction])
        %{state | emitted_direction: direction}
    end
  end
  defp set_motor_direction(state), do: state

  defp actuate(state) when state.automatic_mode_enabled == true do
    frequency = state.target_motor_speed_percentage
      |> D.abs()
      |> D.mult(@frequency_range)

    case state.emitted_frequency == frequency  do
      true -> state
      false ->
        enabled = frequency |> D.gt?(0)
        :ok = GenericController.set_external_pwm(state.actuation_controller, state.external_pwm_id, enabled, @duty_cycle_percentage, frequency)
        %{state | emitted_frequency: frequency}
    end
  end
  defp actuate(state), do: state

  defp init_pid(state) do
    PID.new(
      kp: state.kp,
      ki: state.ki,
      kd: state.kd,
      reset_derivative_when_setpoint_changes: true
    )
  end

  @impl true
  def handle_call({:set_pid_parameters, %{kp: kp, ki: ki, kd: kd}}, _from, state) do
    {:reply, :ok, %{state | kp: kp, ki: ki, kd: kd}}
  end
  def handle_call(:activate_automatic_mode, _from, state) do
    {:reply, :ok, %{state | enable_automatic_mode: true}}
  end
  def handle_call(:deactivate_automatic_mode, _from, state) do
    {:reply, :ok, %{state | enable_automatic_mode: false, target_motor_speed_percentage: @zero}}
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

  def test_activate_automatic_mode do
    GenServer.call(__MODULE__, :activate_automatic_mode)
  end

  def test_deactivate_automatic_mode do
    GenServer.call(__MODULE__, :deactivate_automatic_mode)
  end

  def test_set_pid_parameters(%{kp: kp, ki: ki, kd: kd}) do
    GenServer.call(__MODULE__, {:set_pid_parameters, %{kp: kp, ki: ki, kd: kd}})
  end
end
