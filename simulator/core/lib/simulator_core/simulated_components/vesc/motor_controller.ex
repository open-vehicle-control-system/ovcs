defmodule SimulatorCore.SimulatedComponents.Vesc.MotorController do
  @moduledoc """
  A traction motor behind a VESC, the inverse of
  `VmsCore.Components.Vesc.MotorController`.

  The latest command frame applies until a newer one arrives or
  `:command_timeout_ms` elapses, after which the motor is released, as
  the firmware does. The motor's torque reaches the driven wheels as
  `:wheel_torque_per_ampere_nm` per ampere of motor current, at most
  `:max_current_a`:

    * `set_current` drives by that torque; zero releases the motor.
    * `set_current_brake` brakes by it, down to a stop.
    * `set_rpm` sets a speed the VESC's speed loop holds, a PI loop on
      the gap between that speed and the driven wheels': it drives by
      `:speed_loop_gain_nm_s_m` per m/s of gap, plus the gap's integral
      over `:speed_loop_integral_time_s`, which carries the load the
      gap alone would not, within the current limit. Below `:min_erpm`
      the loop is off and the motor brakes with its full current.
    * `set_duty` sets `duty · :full_duty_speed_m_s` through the same
      loop; zero duty brakes with the full current.

  The motor and gearbox always turn with the driven wheels: their
  inertia at the wheels, `:rotor_inertia_kg_m2` times the ratio
  squared, is in every tick's efforts. It reports `status` (erpm, motor
  current, duty) from the driven wheels' spin and `status_5`
  (tachometer, input voltage) from how far they turned, both through
  `:motor_to_wheel_ratio`.

  ## Options

    * `:name` (`"vesc"`) — the frame-name prefix, the VMS component's
      underscored process name.
    * `:network` (`:misc`).
    * `:pole_pairs`, `:motor_to_wheel_ratio` (required).
    * `:wheel_torque_per_ampere_nm`, `:max_current_a`,
      `:speed_loop_gain_nm_s_m` (required).
    * `:driven_wheels` (required) — the wheels the motor drives, as
      `SimulatorCore.WorldState` names them.
    * `:rotor_inertia_kg_m2` (`0.0`), `:speed_loop_integral_time_s`
      (`0.5`), `:min_erpm` (`900`),
      `:full_duty_speed_m_s` (`3.0`), `:command_timeout_ms` (`1_000`),
      `:input_voltage` (`12.0`).
  """
  @behaviour SimulatorCore.SimulatedComponent

  import SimulatorCore.SimulatedComponent, only: [decimal: 2, float: 2]

  alias SimulatorCore.WorldState

  @defaults %{
    name: "vesc",
    network: :misc,
    rotor_inertia_kg_m2: 0.0,
    speed_loop_integral_time_s: 0.5,
    min_erpm: 900,
    full_duty_speed_m_s: 3.0,
    command_timeout_ms: 1_000,
    input_voltage: 12.0
  }

  @required_options [
    :pole_pairs,
    :motor_to_wheel_ratio,
    :wheel_torque_per_ampere_nm,
    :max_current_a,
    :speed_loop_gain_nm_s_m,
    :driven_wheels
  ]

  @commands [:set_duty, :set_current, :set_current_brake, :set_rpm]

  @impl SimulatorCore.SimulatedComponent
  def init(opts) do
    opts = Map.merge(@defaults, Map.new(opts))

    Enum.each(@required_options, &Map.fetch!(opts, &1))

    state =
      Map.merge(opts, %{
        commands: Map.new(@commands, &{"#{opts.name}_#{&1}", &1}),
        status: "#{opts.name}_status",
        status_5: "#{opts.name}_status_5",
        command: :release,
        command_at_ms: nil,
        driveline_inertia_kg_m2: opts.rotor_inertia_kg_m2 * opts.motor_to_wheel_ratio ** 2,
        tachometer: 0.0,
        last_angle_rad: nil,
        speed_loop_integral_nm: 0.0,
        last_report_ms: nil
      })

    received = for name <- Map.keys(state.commands), do: {state.network, name}

    emitted = [
      {state.network, state.status, status(state, 0, 0.0, 0.0)},
      {state.network, state.status_5, status_5(state)}
    ]

    {state, received, emitted}
  end

  @impl SimulatorCore.SimulatedComponent
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

  @impl SimulatorCore.SimulatedComponent
  def efforts(state, world, now_ms),
    do: [{:driveline_inertia_kg_m2, state.driveline_inertia_kg_m2} | torque(state, world, now_ms)]

  @impl SimulatorCore.SimulatedComponent
  def measure(state, world, now_ms) do
    angle_rad = WorldState.mean(world, state.driven_wheels).angle_rad
    wheel_turns = (angle_rad - (state.last_angle_rad || angle_rad)) / (2 * :math.pi())
    motor_turns = wheel_turns * state.motor_to_wheel_ratio

    state = %{
      state
      | tachometer: state.tachometer + motor_turns * 6 * state.pole_pairs,
        last_angle_rad: angle_rad,
        speed_loop_integral_nm: integrated(state, world, now_ms),
        last_report_ms: now_ms
    }

    {state,
     [
       {state.network, state.status,
        status(
          state,
          erpm(state, world),
          motor_current(state, world, now_ms),
          driven_speed_m_s(state, world)
        )},
       {state.network, state.status_5, status_5(state)}
     ]}
  end

  defp torque(state, world, now_ms) do
    case active_command(state, now_ms) do
      {:rpm, erpm} when abs(erpm) < state.min_erpm -> [{:brake_torque_nm, max_torque_nm(state)}]
      {:duty, duty} when duty == 0 -> [{:brake_torque_nm, max_torque_nm(state)}]
      {:rpm, _erpm} -> [{:drive_torque_nm, speed_loop(state, world, now_ms)}]
      {:duty, _duty} -> [{:drive_torque_nm, speed_loop(state, world, now_ms)}]
      {:current, amperes} -> [{:drive_torque_nm, current_torque_nm(state, amperes)}]
      {:brake, amperes} -> [{:brake_torque_nm, current_torque_nm(state, abs(amperes))}]
      :release -> []
    end
  end

  # The speed the active command asks the loop to hold, nil when the loop is off.
  defp target_speed_m_s(state, world, now_ms) do
    case active_command(state, now_ms) do
      {:rpm, erpm} when abs(erpm) >= state.min_erpm -> speed_of_erpm(state, world, erpm)
      {:duty, duty} when duty != 0 -> duty * state.full_duty_speed_m_s
      _off -> nil
    end
  end

  defp speed_loop(state, world, now_ms) do
    gap_m_s = target_speed_m_s(state, world, now_ms) - driven_speed_m_s(state, world)

    clamp(
      state.speed_loop_gain_nm_s_m * gap_m_s + state.speed_loop_integral_nm,
      max_torque_nm(state)
    )
  end

  # The loop's integral after this tick; zero while the loop is off.
  defp integrated(state, world, now_ms) do
    case {target_speed_m_s(state, world, now_ms), state.last_report_ms} do
      {nil, _last_report_ms} ->
        0.0

      {_target, nil} ->
        state.speed_loop_integral_nm

      {target_m_s, last_report_ms} ->
        gap_m_s = target_m_s - driven_speed_m_s(state, world)
        dt_s = (now_ms - last_report_ms) / 1000
        gain = state.speed_loop_gain_nm_s_m / state.speed_loop_integral_time_s
        clamp(state.speed_loop_integral_nm + gain * gap_m_s * dt_s, max_torque_nm(state))
    end
  end

  defp current_torque_nm(state, amperes),
    do: clamp(amperes, state.max_current_a) * state.wheel_torque_per_ampere_nm

  defp clamp(value, limit), do: value |> max(-limit) |> min(limit)

  defp max_torque_nm(state), do: state.max_current_a * state.wheel_torque_per_ampere_nm

  defp driven_speed_m_s(state, world),
    do: WorldState.mean(world, state.driven_wheels).omega_rad_s * world.wheel_radius_m

  defp active_command(%{command_at_ms: nil}, _now_ms), do: :release

  defp active_command(state, now_ms) do
    if now_ms - state.command_at_ms > state.command_timeout_ms, do: :release, else: state.command
  end

  defp motor_current(state, world, now_ms) do
    case torque(state, world, now_ms) do
      [{:drive_torque_nm, torque}] -> torque / state.wheel_torque_per_ampere_nm
      [{:brake_torque_nm, torque}] -> -torque / state.wheel_torque_per_ampere_nm
      [] -> 0.0
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
  def erpm(state, world) do
    wheel_rpm = WorldState.mean(world, state.driven_wheels).omega_rad_s / (2 * :math.pi()) * 60
    round(wheel_rpm * state.motor_to_wheel_ratio * state.pole_pairs)
  end

  defp speed_of_erpm(state, world, erpm) do
    erpm / state.pole_pairs / state.motor_to_wheel_ratio / 60 * 2 * :math.pi() *
      world.wheel_radius_m
  end

  defp int32(value) do
    <<wrapped::signed-integer-size(32)>> = <<value::signed-integer-size(32)>>
    wrapped
  end
end
