defmodule SimulatorCore.SimulatedComponents.OVCS.SteeringColumn do
  @moduledoc """
  The OVCS steering column, the inverse of
  `VmsCore.Components.OVCS.SteeringColumn`: a stepper turning the
  column, and the Bosch LWS reading its angle on `lws_status`.

  While its power relay is requested and its external PWM is enabled,
  the column turns at the PWM's frequency, in steps per second, over
  `:steps_per_column_degree`: clockwise while its direction pin is
  high, as the VMS drives it. It stops at `:column_limit_deg` either
  side of centre, as at the rack's end. The LWS reports a clockwise
  angle as negative, which the VMS negates. The front wheels turn by
  the column angle over `:steering_ratio`, and a clockwise column
  steers right.

  ## Options

    * `:network` (required) — the LWS's network.
    * `:power_relay_controller`, `:power_relay_pin` (required) — the
      stepper driver's power relay: the frame-name prefix of its
      generic controller, and its digital pin.
    * `:actuation_controller`, `:direction_pin`, `:external_pwm_id`
      (required) — the generic controller stepping the motor, its
      direction pin and its external PWM.
    * `:controller_network` (`:ovcs`).
    * `:steps_per_column_degree`, `:steering_ratio`, `:column_limit_deg`
      (required).
  """
  @behaviour SimulatorCore.SimulatedComponent

  import SimulatorCore.SimulatedComponent, only: [decimal: 2, float: 2]

  alias SimulatorCore.SimulatedComponents.OVCS.GenericController.DigitalPinRequest

  # The most lws_status's 8-bit angular speed holds, at 4 °/s per bit.
  @max_reported_angular_speed_deg_s 1_020

  @impl SimulatorCore.SimulatedComponent
  def init(opts) do
    opts = Map.new(opts)
    actuation_controller = Map.fetch!(opts, :actuation_controller)

    state = %{
      network: Map.fetch!(opts, :network),
      controller_network: Map.get(opts, :controller_network, :ovcs),
      power_request: DigitalPinRequest.frame_name(Map.fetch!(opts, :power_relay_controller)),
      power_pin: Map.fetch!(opts, :power_relay_pin),
      direction_request: DigitalPinRequest.frame_name(actuation_controller),
      direction_pin: Map.fetch!(opts, :direction_pin),
      pwm_request:
        "#{actuation_controller}_external_pwm#{Map.fetch!(opts, :external_pwm_id)}_request",
      steps_per_column_degree: Map.fetch!(opts, :steps_per_column_degree),
      steering_ratio: Map.fetch!(opts, :steering_ratio),
      column_limit_deg: Map.fetch!(opts, :column_limit_deg),
      powered: false,
      clockwise: false,
      step_frequency_hz: 0.0,
      column_angle_deg: 0.0,
      angular_speed_deg_s: 0.0,
      last_report_ms: nil
    }

    received =
      Enum.map(
        [state.power_request, state.direction_request, state.pwm_request],
        &{state.controller_network, &1}
      )

    {state, received, [{state.network, "lws_status", lws_status(state)}]}
  end

  # The power and direction pins can share one controller, so one frame
  # may carry both.
  @impl SimulatorCore.SimulatedComponent
  def handle_frame(name, signals, state, _now_ms) do
    state
    |> read_power(name, signals)
    |> read_direction(name, signals)
    |> read_steps(name, signals)
  end

  @impl SimulatorCore.SimulatedComponent
  def actuations(state, _vehicle, _now_ms) do
    wheel_angle_rad = state.column_angle_deg / state.steering_ratio * :math.pi() / 180
    [{:steering, -wheel_angle_rad}]
  end

  @impl SimulatorCore.SimulatedComponent
  def report(state, _vehicle, now_ms) do
    state = turn(state, now_ms)
    {state, [{state.network, "lws_status", lws_status(state)}]}
  end

  defp read_power(%{power_request: name, power_pin: pin} = state, name, signals),
    do: %{state | powered: DigitalPinRequest.enabled?(signals, pin)}

  defp read_power(state, _name, _signals), do: state

  defp read_direction(%{direction_request: name, direction_pin: pin} = state, name, signals),
    do: %{state | clockwise: DigitalPinRequest.enabled?(signals, pin)}

  defp read_direction(state, _name, _signals), do: state

  defp read_steps(%{pwm_request: name} = state, name, %{"enabled" => %{value: true}} = signals),
    do: %{state | step_frequency_hz: float(signals, "frequency")}

  defp read_steps(%{pwm_request: name} = state, name, _signals),
    do: %{state | step_frequency_hz: 0.0}

  defp read_steps(state, _name, _signals), do: state

  defp turn(%{last_report_ms: nil} = state, now_ms), do: %{state | last_report_ms: now_ms}

  defp turn(state, now_ms) do
    elapsed_s = (now_ms - state.last_report_ms) / 1000

    column_angle_deg =
      (state.column_angle_deg + commanded_speed_deg_s(state) * elapsed_s)
      |> max(-state.column_limit_deg)
      |> min(state.column_limit_deg)

    angular_speed_deg_s =
      if elapsed_s > 0,
        do: (column_angle_deg - state.column_angle_deg) / elapsed_s,
        else: state.angular_speed_deg_s

    %{
      state
      | column_angle_deg: column_angle_deg,
        angular_speed_deg_s: angular_speed_deg_s,
        last_report_ms: now_ms
    }
  end

  defp commanded_speed_deg_s(%{powered: false}), do: 0.0

  defp commanded_speed_deg_s(state) do
    speed = state.step_frequency_hz / state.steps_per_column_degree
    if state.clockwise, do: speed, else: -speed
  end

  defp lws_status(state) do
    angular_speed_deg_s = min(abs(state.angular_speed_deg_s), @max_reported_angular_speed_deg_s)

    %{
      "steering_wheel_angle" => decimal(-state.column_angle_deg, 1),
      "steering_wheel_angular_speed" => decimal(angular_speed_deg_s, 0),
      "steering_wheel_trimming_valid" => true,
      "steering_wheel_calibration_valid" => true,
      "steering_wheel_sensor_ready" => true,
      "checksum" => 0,
      "counter" => 0
    }
  end
end
