defmodule RosBridge.Simulator.SimulatedComponents.Vesc.MotorController do
  @moduledoc """
  A traction motor behind a VESC, the inverse of
  `VmsCore.Components.Vesc.MotorController`.

  The latest command frame applies until a newer one arrives or
  `:command_timeout_ms` elapses, after which the motor is released, as
  the firmware does:

    * `set_rpm` sets the setpoint's speed; below `:min_erpm` the VESC's
      speed loop is off and the motor brakes, a setpoint of zero.
    * `set_duty` sets `duty · :full_duty_speed_m_s`; zero duty brakes.
    * `set_current` accelerates it by `current · :acceleration_per_ampere`;
      zero releases the motor.
    * `set_current_brake` decelerates it by the same scale, down to a
      stop.

  It reports `status` (erpm, motor current, duty) from the wheels'
  measured speed and `status_5` (tachometer, input voltage) from how far
  they turned, both through `:motor_to_wheel_ratio`.

  ## Options

    * `:name` (`"vesc"`) — the frame-name prefix, the VMS component's
      underscored process name.
    * `:network` (`:misc`).
    * `:pole_pairs`, `:motor_to_wheel_ratio` (required).
    * `:min_erpm` (`900`), `:full_duty_speed_m_s` (`3.0`),
      `:acceleration_per_ampere` (`0.5`), `:command_timeout_ms` (`1_000`),
      `:input_voltage` (`12.0`).
  """
  @behaviour RosBridge.Simulator.SimulatedComponent

  import RosBridge.Simulator.SimulatedComponent, only: [decimal: 2, float: 2]

  @defaults %{
    name: "vesc",
    network: :misc,
    min_erpm: 900,
    full_duty_speed_m_s: 3.0,
    acceleration_per_ampere: 0.5,
    command_timeout_ms: 1_000,
    input_voltage: 12.0
  }

  @commands [:set_duty, :set_current, :set_current_brake, :set_rpm]

  @impl RosBridge.Simulator.SimulatedComponent
  def init(opts) do
    opts = Map.merge(@defaults, Map.new(opts))
    _ = {Map.fetch!(opts, :pole_pairs), Map.fetch!(opts, :motor_to_wheel_ratio)}

    state =
      Map.merge(opts, %{
        commands: Map.new(@commands, &{"#{opts.name}_#{&1}", &1}),
        status: "#{opts.name}_status",
        status_5: "#{opts.name}_status_5",
        command: :release,
        command_at_ms: nil,
        tachometer: 0.0
      })

    received = for name <- Map.keys(state.commands), do: {state.network, name}

    emitted = [
      {state.network, state.status, status(state, 0, 0.0, 0.0)},
      {state.network, state.status_5, status_5(state)}
    ]

    {state, received, emitted}
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def handle_frame(name, signals, state, now_ms) do
    command =
      case state.commands[name] do
        :set_duty -> {:duty, float(signals, "duty")}
        :set_current -> {:current, float(signals, "current")}
        :set_current_brake -> {:brake, float(signals, "current")}
        :set_rpm -> {:rpm, float(signals, "erpm")}
      end

    %{state | command: command, command_at_ms: now_ms}
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def actuations(state, vehicle, now_ms) do
    case active_command(state, now_ms) do
      {:rpm, erpm} when abs(erpm) < state.min_erpm -> [{:speed, 0.0}]
      {:rpm, erpm} -> [{:speed, speed_of_erpm(state, vehicle, erpm)}]
      {:duty, duty} -> [{:speed, duty * state.full_duty_speed_m_s}]
      {:current, amperes} -> [{:acceleration, amperes * state.acceleration_per_ampere}]
      {:brake, amperes} -> [{:deceleration, amperes * state.acceleration_per_ampere}]
      :release -> []
    end
  end

  @impl RosBridge.Simulator.SimulatedComponent
  def report(state, vehicle, _dt_s, now_ms) do
    motor_turns = vehicle.wheel_turns_step * state.motor_to_wheel_ratio
    state = %{state | tachometer: state.tachometer + motor_turns * 6 * state.pole_pairs}

    {state,
     [
       {state.network, state.status,
        status(
          state,
          erpm(state, vehicle),
          motor_current(state, now_ms),
          vehicle.measured_speed_m_s
        )},
       {state.network, state.status_5, status_5(state)}
     ]}
  end

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
      "tachometer" => int32(floor(state.tachometer)),
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
end
