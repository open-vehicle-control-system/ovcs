defmodule OvcsMini.Simulator do
  @moduledoc """
  The OVCS Mini's simulated hardware, `OvcsMini.simulator/0`: the parts
  the VMS drives, with the drivetrain of
  `OvcsMini.Vms.Composer.drivetrain/0` and the geometry of
  `OvcsMini.geometry/0`. Its frames are `vms.yml`'s the other way round,
  on the VMS's host interfaces.

  The radio starts with its sticks centred, then moves channel 6 through
  `:radio` to `:ros` and channel 5 to the commander
  `OVCS_SIMULATOR_COMMANDER` names (`teleop`, or `autonomous` by
  default), each a second apart.
  """

  alias OvcsMini.Vms.Composer
  alias SimulatorCore.SimulatedComponents, as: Simulated

  # The URDF's total mass.
  @mass_kg 2.41
  # Not measured: plausible figures for a 1/10 truck on a 2S pack.
  @battery_voltage 7.4
  @acceleration_per_ampere 0.5
  @vesc_speed_time_constant_s 0.25
  # The Mini's VESC Tool setting, see docs/vms/drivers.md.
  @vesc_minimum_erpm 300
  # Shaft-driven 4WD: the motor turns with all four wheels.
  @driven_wheels [:front_left, :front_right, :rear_left, :rear_right]

  @doc "The acceleration a simulated ampere of motor current gives, in m/s² per ampere."
  def acceleration_per_ampere, do: @acceleration_per_ampere

  @doc "The simulated vehicle's mass, in kg."
  def mass_kg, do: @mass_kg

  @doc "`t:OvcsVehicle.simulator/0` for the OVCS Mini."
  @spec simulator() :: OvcsVehicle.simulator()
  def simulator do
    drivetrain = Composer.drivetrain()
    geometry = OvcsMini.geometry()

    %{
      can_config_path: "can/simulator.yml",
      can_mapping: Composer.default_can_mapping(:host),
      vehicle: %{
        wheelbase_m: geometry.wheelbase,
        wheel_radius_m: geometry.wheel_radius,
        mass_kg: @mass_kg,
        # Friction is the motor current the Mini needs to start rolling.
        rolling_deceleration_m_s2: drivetrain.min_motor_current * @acceleration_per_ampere
      },
      simulated_components: [
        {Simulated.Vesc.MotorController,
         pole_pairs: drivetrain.pole_pairs,
         motor_to_wheel_ratio: drivetrain.motor_to_wheel_ratio,
         min_erpm: @vesc_minimum_erpm,
         wheel_torque_per_ampere_nm: @mass_kg * @acceleration_per_ampere * geometry.wheel_radius,
         max_current_a: drivetrain.max_motor_current,
         speed_loop_gain_nm_s_m: @mass_kg * geometry.wheel_radius / @vesc_speed_time_constant_s,
         driven_wheels: @driven_wheels,
         input_voltage: @battery_voltage},
        {Simulated.OVCS.GenericController,
         analog_pins: %{1 => pm12s3_reading(@battery_voltage)},
         pulse: %{
           shaft_turns_per_wheel_turn:
             drivetrain.motor_to_wheel_ratio * drivetrain.pinion_teeth / drivetrain.spur_teeth,
           pulses_per_revolution: drivetrain.pulses_per_revolution
         }},
        {Simulated.Traxxas.Steering,
         steering_limit_rad: geometry.steering_limit,
         steering_sign: drivetrain.steering_sign,
         neutral: drivetrain.steering_trim},
        {Simulated.OVCS.RadioControl, radio_control_script()}
      ]
    }
  end

  # The PM12S-3's 1:21 divider read by the controller's 14-bit, 5 V ADC.
  defp pm12s3_reading(voltage), do: round(voltage / 21 / 5 * 16_383)

  defp radio_control_script do
    commander = if System.get_env("OVCS_SIMULATOR_COMMANDER") == "teleop", do: 1000, else: 2000

    [
      channels: %{1 => 1500, 2 => 1500, 5 => 1000, 6 => 1000},
      steps: [{3_000, %{6 => 1500}}, {4_000, %{6 => 2000}}, {5_000, %{5 => commander}}]
    ]
  end
end
