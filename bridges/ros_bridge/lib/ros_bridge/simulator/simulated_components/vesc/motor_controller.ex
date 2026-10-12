defmodule RosBridge.Simulator.SimulatedComponents.Vesc.MotorController do
  @moduledoc """
  A traction motor behind a VESC, the inverse of
  `VmsCore.Components.Vesc.MotorController`.

  The latest command frame applies until a newer one arrives or
  `:command_timeout_ms` elapses, after which the motor is released, as
  the firmware does:

    * `set_rpm` drives the vehicle to the setpoint's speed with time
      constant `:speed_time_constant_s`, compensating rolling resistance
      the way the VESC's speed loop does. Below `:min_erpm` the loop is
      off and the motor brakes to a stop.
    * `set_duty` drives it to `duty · :full_duty_speed_m_s` the same
      way; zero duty brakes.
    * `set_current` accelerates it by `current · :acceleration_per_ampere`;
      zero releases the motor.
    * `set_current_brake` decelerates it by the same scale, down to a
      stop.

  It reports `status` (erpm, motor current, duty) and `status_5`
  (tachometer, input voltage), both from the vehicle's speed through
  `:motor_to_wheel_ratio`.

  ## Options

    * `:name` (`"vesc"`) — the frame-name prefix, the VMS component's
      underscored process name.
    * `:network` (`:misc`).
    * `:pole_pairs`, `:motor_to_wheel_ratio` (required).
    * `:min_erpm` (`900`), `:speed_time_constant_s` (`0.15`),
      `:full_duty_speed_m_s` (`3.0`), `:acceleration_per_ampere` (`0.5`),
      `:command_timeout_ms` (`1_000`), `:input_voltage` (`12.0`).
  """
  @behaviour RosBridge.Simulator.SimulatedComponent

  alias Cantastic.Signal

  @defaults %{
    name: "vesc",
    network: :misc,
    min_erpm: 900,
    speed_time_constant_s: 0.15,
    full_duty_speed_m_s: 3.0,
    acceleration_per_ampere: 0.5,
    command_timeout_ms: 1_000,
    input_voltage: 12.0
  }

  @impl RosBridge.Simulator.SimulatedComponent
  def init(opts) do
    state =
      @defaults
      |> Map.merge(Map.new(opts))
      |> Map.merge(%{command: :release, command_at_ms: nil, tachometer: 0.0})

    for key <- [:pole_pairs, :motor_to_wheel_ratio],
        not Map.has_key?(state, key),
        do: raise(ArgumentError, "#{inspect(__MODULE__)} needs #{inspect(key)}")

    names = frame_names(state.name)
    state = Map.put(state, :frames, names)

    received =
      for frame <- [:set_duty, :set_current, :set_current_brake, :set_rpm],
          do: {state.network, names[frame]}

    emitted = [
      {state.network, names.status, status(state, 0, 0.0, 0.0)},
      {state.network, names.status_5, status_5(state)}
    ]

    {state, received, emitted}
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def handle_frame(name, signals, state, now_ms) do
    command =
      case frame_kind(state.frames, name) do
        :set_duty -> {:duty, value(signals, "duty")}
        :set_current -> {:current, value(signals, "current")}
        :set_current_brake -> {:brake, value(signals, "current")}
        :set_rpm -> {:rpm, value(signals, "erpm")}
      end

    %{state | command: command, command_at_ms: now_ms}
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def actuations(state, vehicle, now_ms) do
    case active_command(state, now_ms) do
      {:rpm, erpm} when abs(erpm) < state.min_erpm -> brake_to_stop(state, vehicle)
      {:rpm, erpm} -> hold_speed(state, vehicle, speed_of_erpm(state, vehicle, erpm))
      {:duty, duty} when duty == 0.0 -> brake_to_stop(state, vehicle)
      {:duty, duty} -> hold_speed(state, vehicle, duty * state.full_duty_speed_m_s)
      {:current, amperes} -> [{:acceleration, amperes * state.acceleration_per_ampere}]
      {:brake, amperes} -> [{:deceleration, amperes * state.acceleration_per_ampere}]
      :release -> []
    end
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def step(state, vehicle, _dt_s, now_ms) do
    motor_turns = vehicle.wheel_turns_step * state.motor_to_wheel_ratio
    state = %{state | tachometer: state.tachometer + motor_turns * 6 * state.pole_pairs}

    {state,
     [
       {state.network, state.frames.status,
        status(
          state,
          erpm(state, vehicle),
          motor_current(state, now_ms),
          vehicle.measured_speed_m_s
        )},
       {state.network, state.frames.status_5, status_5(state)}
     ]}
  end

  # The speed loop's integrator holds the setpoint against rolling resistance.
  defp hold_speed(state, vehicle, target) do
    feedforward =
      if target == 0.0, do: 0.0, else: sign(target) * vehicle.rolling_deceleration_m_s2

    [
      {:acceleration,
       (target - vehicle.measured_speed_m_s) / state.speed_time_constant_s + feedforward}
    ]
  end

  defp brake_to_stop(state, vehicle),
    do: [{:deceleration, abs(vehicle.measured_speed_m_s) / state.speed_time_constant_s}]

  defp active_command(%{command_at_ms: nil}, _now_ms), do: :release

  defp active_command(state, now_ms) do
    if now_ms - state.command_at_ms > state.command_timeout_ms, do: :release, else: state.command
  end

  defp motor_current(state, now_ms) do
    case active_command(state, now_ms) do
      {:current, amperes} -> amperes
      {:brake, amperes} -> -amperes
      _ -> 0.0
    end
  end

  defp status(state, erpm, motor_current, speed_m_s) do
    %{
      "erpm" => erpm,
      "motor_current" => decimal(motor_current, 1),
      "duty" => decimal(speed_m_s / state.full_duty_speed_m_s, 3)
    }
  end

  defp status_5(state) do
    %{
      "tachometer" => int32(trunc(state.tachometer)),
      "input_voltage" => decimal(state.input_voltage, 1)
    }
  end

  @doc false
  def erpm(state, vehicle) do
    wheel_rpm = vehicle.measured_speed_m_s / (2 * :math.pi() * vehicle.wheel_radius_m) * 60
    round(wheel_rpm * state.motor_to_wheel_ratio * state.pole_pairs)
  end

  defp speed_of_erpm(state, vehicle, erpm) do
    erpm / state.pole_pairs / state.motor_to_wheel_ratio / 60 * 2 * :math.pi() *
      vehicle.wheel_radius_m
  end

  defp int32(value) do
    <<wrapped::signed-integer-size(32)>> = <<value::signed-integer-size(32)>>
    wrapped
  end

  defp frame_kind(frames, name) do
    Enum.find_value([:set_duty, :set_current, :set_current_brake, :set_rpm], fn kind ->
      if frames[kind] == name, do: kind
    end)
  end

  defp value(signals, name) do
    case signals[name] do
      %Signal{value: %Decimal{} = value} -> Decimal.to_float(value)
      %Signal{value: value} -> value * 1.0
    end
  end

  defp decimal(value, places), do: (value * 1.0) |> Decimal.from_float() |> Decimal.round(places)

  defp sign(value) when value < 0, do: -1.0
  defp sign(_value), do: 1.0

  @doc false
  def frame_names(name) do
    Map.new(
      [:set_duty, :set_current, :set_current_brake, :set_rpm, :status, :status_5],
      fn kind -> {kind, "#{name}_#{kind}"} end
    )
  end
end
