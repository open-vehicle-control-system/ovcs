defmodule VmsCore.Components.OVCS.SteeringColumn do
  @moduledoc """
  The OVCS steering column: a VW steering column turned by a stepper
  motor, its angle read from a Bosch LWS sensor on the CAN network named by
  `:network`.

  While the selected control level is `:radio`, it powers the stepper
  driver through a relay, smooths the selected `:requested_steering`
  with an `OvcsControl.InputFilter`, scales it to a desired angle and
  closes the loop with an `OvcsControl.PID` on the measured angle. The
  PID output sets the step frequency of an external PWM and the
  direction pin of a generic controller. Any other control level cuts
  the relay.

  The PID gains and the filter's deadband and alpha are tunable live
  from the dashboard through `trigger_action/2`.

  ## Options

    * `:network` — the CAN network it sits on, as named in the vehicle's
      CAN topology.
    * `:selected_control_level_source` — publishes
      `:selected_control_level` and `:requested_steering_source`.
    * `:power_relay_controller`, `:power_relay_pin` — the stepper
      driver's power relay.
    * `:actuation_controller` — the generic controller driving the
      stepper.
    * `:direction_pin` — its digital pin for the direction.
    * `:external_pwm_id` — its external PWM for the steps.
    * `:max_steering_angle_deg` — the column angle of a full
      `:requested_steering`.
    * `:kp`, `:ki`, `:kd` — the PID gains to start from, default 0.07,
      0.005 and 0.005.
    * `:input_deadband`, `:input_alpha` — the input filter's settings to
      start from, default 0 and 0.2.
  """
  use GenServer
  alias Cantastic.{Emitter, Frame, Receiver, Signal}
  alias OvcsBus, as: Bus
  alias Decimal, as: D
  alias OvcsControl.{InputFilter, PID}
  alias VmsCore.Components.OVCS.GenericController

  @zero D.new(0)
  @loop_period_ms 10
  # Step frequency at full PID output.
  @max_step_frequency_hz 65_535
  @step_duty_cycle D.new("0.5")
  @direction_pin_levels %{clockwise: true, counter_clockwise: false}

  @default_tuning %{
    kp: "0.07",
    ki: "0.005",
    kd: "0.005",
    input_deadband: "0",
    input_alpha: "0.2"
  }
  @lws_command_duration_ms 500

  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl GenServer
  def init(
        %{
          network: network,
          selected_control_level_source: selected_control_level_source,
          power_relay_controller: power_relay_controller,
          power_relay_pin: power_relay_pin,
          actuation_controller: actuation_controller,
          direction_pin: direction_pin,
          external_pwm_id: external_pwm_id,
          max_steering_angle_deg: max_steering_angle_deg
        } = args
      ) do
    tuning =
      Map.new(@default_tuning, fn {key, default} -> {key, D.new(Map.get(args, key, default))} end)

    :ok =
      Emitter.configure(network, "lws_config", %{
        parameters_builder_function: :default,
        initial_data: %{
          "command" => "reset_angle_calibration_status"
        }
      })

    :ok = Receiver.subscribe(self(), network, ["lws_status"])
    Bus.subscribe("messages")
    {:ok, timer} = :timer.send_interval(@loop_period_ms, :loop)

    {:ok,
     %{
       network: network,
       loop_timer: timer,
       angle: @zero,
       angular_speed: @zero,
       trimming_valid: false,
       calibration_valid: false,
       sensor_ready: false,
       power_relay_controller: power_relay_controller,
       actuation_controller: actuation_controller,
       requested_steering_source: nil,
       requested_steering: @zero,
       power_relay_pin: power_relay_pin,
       direction_pin: direction_pin,
       external_pwm_id: external_pwm_id,
       emitted_frequency: nil,
       emitted_direction: nil,
       pid: nil,
       input_filter: nil,
       automatic_mode_enabled: false,
       desired_angle: @zero,
       target_motor_speed_percentage: @zero,
       selected_control_level_source: selected_control_level_source,
       selected_control_level: nil,
       max_steering_angle_deg: D.new(max_steering_angle_deg),
       kp: tuning.kp,
       ki: tuning.ki,
       kd: tuning.kd,
       input_deadband: tuning.input_deadband,
       input_alpha: tuning.input_alpha
     }}
  end

  @impl GenServer
  def handle_info(:loop, state) do
    state =
      state
      |> toggle_automatic_mode()
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

    {:noreply,
     %{
       state
       | angle: 0 |> D.sub(angle),
         angular_speed: angular_speed,
         trimming_valid: trimming_valid,
         calibration_valid: calibration_valid,
         sensor_ready: sensor_ready
     }}
  end

  def handle_info(
        %Bus.Message{
          name: :selected_control_level,
          value: selected_control_level,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    {:noreply, %{state | selected_control_level: selected_control_level}}
  end

  def handle_info(
        %Bus.Message{
          name: :requested_steering_source,
          value: requested_steering_source,
          source: source
        },
        state
      )
      when source == state.selected_control_level_source do
    {:noreply, %{state | requested_steering_source: requested_steering_source}}
  end

  def handle_info(
        %Bus.Message{name: :requested_steering, value: requested_steering, source: source},
        state
      )
      when source == state.requested_steering_source do
    {:noreply, %{state | requested_steering: requested_steering}}
  end

  def handle_info(%Bus.Message{}, state) do
    {:noreply, state}
  end

  defp toggle_automatic_mode(state) do
    automatic_mode_requested = state.selected_control_level == :radio

    cond do
      automatic_mode_requested && !state.automatic_mode_enabled ->
        pid = init_pid(state)
        input_filter = init_input_filter(state)

        :ok =
          GenericController.set_digital_value(
            state.power_relay_controller,
            state.power_relay_pin,
            true
          )

        %{state | pid: pid, input_filter: input_filter, automatic_mode_enabled: true}

      !automatic_mode_requested && state.automatic_mode_enabled ->
        :ok =
          GenericController.set_digital_value(
            state.power_relay_controller,
            state.power_relay_pin,
            false
          )

        %{state | automatic_mode_enabled: false}

      true ->
        state
    end
  end

  defp set_desired_angle(state) when state.automatic_mode_enabled == true do
    input_filter = InputFilter.apply(state.input_filter, state.requested_steering)
    desired_angle = input_filter.value |> D.mult(state.max_steering_angle_deg)
    %{state | input_filter: input_filter, desired_angle: desired_angle}
  end

  defp set_desired_angle(state), do: state

  defp set_motor_speed_percentage(state) when state.automatic_mode_enabled == true do
    pid = PID.iterate(state.pid, state.angle, state.desired_angle)
    target_motor_speed_percentage = pid.output
    %{state | pid: pid, target_motor_speed_percentage: target_motor_speed_percentage}
  end

  defp set_motor_speed_percentage(state), do: state

  defp set_motor_direction(state) when state.automatic_mode_enabled == true do
    direction =
      case state.target_motor_speed_percentage |> D.lt?(0) do
        true -> :counter_clockwise
        false -> :clockwise
      end

    case state.emitted_direction == direction do
      true ->
        state

      false ->
        :ok =
          GenericController.set_digital_value(
            state.actuation_controller,
            state.direction_pin,
            @direction_pin_levels[direction]
          )

        %{state | emitted_direction: direction}
    end
  end

  defp set_motor_direction(state), do: state

  defp actuate(state) when state.automatic_mode_enabled == true do
    frequency =
      state.target_motor_speed_percentage
      |> D.abs()
      |> D.mult(@max_step_frequency_hz)

    case state.emitted_frequency == frequency do
      true ->
        state

      false ->
        enabled = frequency |> D.gt?(0)

        :ok =
          GenericController.set_external_pwm(
            state.actuation_controller,
            state.external_pwm_id,
            enabled,
            @step_duty_cycle,
            frequency
          )

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

  defp init_input_filter(state) do
    InputFilter.new(
      deadband: state.input_deadband,
      alpha: state.input_alpha,
      initial_value: state.requested_steering
    )
  end

  @impl GenServer
  def handle_call(:network, _from, state), do: {:reply, state.network, state}

  def handle_call({:set_pid_parameters, %{kp: kp, ki: ki, kd: kd}}, _from, state) do
    {:reply, :ok, %{state | kp: kp, ki: ki, kd: kd}}
  end

  # The stored gain seeds the next PID; a running PID takes it at once.
  def handle_call({:set_pid_parameter, parameter, raw_gain}, _from, state)
      when parameter in ["kp", "ki", "kd"] do
    key = String.to_existing_atom(parameter)
    gain = parse_decimal(raw_gain)
    pid = if state.pid, do: Map.put(state.pid, key, gain), else: state.pid

    {:reply, :ok, %{state | pid: pid} |> Map.put(key, gain)}
  end

  # The stored setting seeds the next filter; a running filter takes it at once.
  def handle_call({:set_filter_parameter, parameter, raw_setting}, _from, state)
      when parameter in ["deadband", "alpha"] do
    filter_key = String.to_existing_atom(parameter)
    state_key = String.to_existing_atom("input_" <> parameter)
    setting = parse_decimal(raw_setting)

    input_filter =
      if state.input_filter,
        do: Map.put(state.input_filter, filter_key, setting),
        else: state.input_filter

    {:reply, :ok, %{state | input_filter: input_filter} |> Map.put(state_key, setting)}
  end

  defp parse_decimal(text) when is_binary(text), do: text |> String.trim() |> D.new()
  defp parse_decimal(number) when is_integer(number), do: D.new(number)
  defp parse_decimal(number) when is_float(number), do: D.from_float(number)

  defp emit_metrics(state) do
    Bus.broadcast("messages", %Bus.Message{name: :angle, value: state.angle, source: __MODULE__})

    Bus.broadcast("messages", %Bus.Message{
      name: :angular_speed,
      value: state.angular_speed,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :trimming_valid,
      value: state.trimming_valid,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :calibration_valid,
      value: state.calibration_valid,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :sensor_ready,
      value: state.sensor_ready,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :desired_angle,
      value: state.desired_angle |> D.round(2),
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :target_motor_speed_percentage,
      value: state.target_motor_speed_percentage,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :automatic_mode_enabled,
      value: state.automatic_mode_enabled,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{name: :kp, value: state.kp, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :ki, value: state.ki, source: __MODULE__})
    Bus.broadcast("messages", %Bus.Message{name: :kd, value: state.kd, source: __MODULE__})

    Bus.broadcast("messages", %Bus.Message{
      name: :input_deadband,
      value: state.input_deadband,
      source: __MODULE__
    })

    Bus.broadcast("messages", %Bus.Message{
      name: :input_alpha,
      value: state.input_alpha,
      source: __MODULE__
    })

    state
  end

  @doc """
  Dashboard actions:

    * `"calibrate_angle_0"` — resets the LWS calibration, then takes the
      current angle as zero.
    * `"set_pid_parameter"` — sets `"parameter"` (`"kp"`, `"ki"` or
      `"kd"`) to `"value"`.
    * `"set_filter_parameter"` — sets the input filter's `"parameter"`
      (`"deadband"` or `"alpha"`) to `"value"`.
  """
  def trigger_action("calibrate_angle_0", _parameters) do
    network = GenServer.call(__MODULE__, :network)
    :ok = send_lws_command(network, "reset_angle_calibration_status")
    :timer.sleep(@lws_command_duration_ms)
    :ok = send_lws_command(network, "set_angle_zero")
  end

  def trigger_action("set_pid_parameter", %{"parameter" => parameter, "value" => raw_gain})
      when parameter in ["kp", "ki", "kd"] do
    GenServer.call(__MODULE__, {:set_pid_parameter, parameter, raw_gain})
  end

  def trigger_action("set_filter_parameter", %{"parameter" => parameter, "value" => raw_setting})
      when parameter in ["deadband", "alpha"] do
    GenServer.call(__MODULE__, {:set_filter_parameter, parameter, raw_setting})
  end

  defp send_lws_command(network, command) do
    :ok =
      Emitter.update(network, "lws_config", fn frame_data ->
        %{frame_data | "command" => command}
      end)

    :ok = Emitter.enable(network, "lws_config")
    :timer.sleep(@lws_command_duration_ms)
    :ok = Emitter.disable(network, "lws_config")
  end

  @doc "Replaces the three PID gains used the next time the PID is built."
  def set_pid_parameters(%{kp: kp, ki: ki, kd: kd}) do
    GenServer.call(__MODULE__, {:set_pid_parameters, %{kp: kp, ki: ki, kd: kd}})
  end
end
