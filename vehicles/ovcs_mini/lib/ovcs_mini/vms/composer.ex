defmodule OvcsMini.Vms.Composer do
  @moduledoc """
    Combine all the modules required to run the OVCS Mini car
  """
  @behaviour VmsCore.Vehicle

  alias VmsCore.Components.{OVCS, Traxxas, Vesc}
  alias VmsCore.Managers
  alias OvcsMini.Vms

  @impl VmsCore.Vehicle
  defdelegate generic_controllers, to: OvcsMini.Vms.Composer.GenericController
  @impl VmsCore.Vehicle
  defdelegate dashboard_configuration, to: OvcsMini.Vms.Composer.Dashboard

  @impl VmsCore.Vehicle
  def can_config_otp_app, do: :ovcs_mini
  @impl VmsCore.Vehicle
  def can_config_path, do: "can/vms.yml"

  @impl VmsCore.Vehicle
  def default_can_mapping(:host), do: "ovcs:vcan0,misc:vcan1"
  def default_can_mapping(:target), do: "ovcs:spi0.0,misc:spi1.0"

  # Speed in m/s at a linear request of 1: what `RosVelocityCommand`
  # normalises the planner's velocity against, and the speed the VESC's
  # speed loop holds for it, through the gearing below. Nav2's `vx_max`.
  @max_speed_m_s 1.5

  # Throttle feel for hands, see `OVCS.InputCurve`. The dead zone
  # matches `RadioControl.Throttle`'s braking threshold, so a trigger
  # that reads as braking also reads as a request.
  @throttle_deadzone Decimal.new("0.05")
  @throttle_expo Decimal.new("0.5")
  # Fraction of the motor's full output at full stick, in drive and in
  # reverse gear.
  @max_throttle Decimal.new("0.25")
  @max_reverse_throttle Decimal.new("0.25")
  # Amperes of braking current at full stick back.
  @max_brake_current 10

  # Motor turns per wheel turn: Traxxas's stock ratio, for the stock
  # 13-tooth pinion on the 54-tooth spur.
  @motor_to_wheel_ratio 11.82
  @pinion_teeth 13
  @spur_teeth 54

  # One magnet in the spur gear: one pulse per spur turn.
  @pulses_per_revolution 1

  # Motor rpm at `@max_speed_m_s`, what a full linear request asks the
  # VESC for.
  @max_motor_rotation_per_minute @max_speed_m_s * 60 /
                                   (2 * :math.pi() * OvcsMini.geometry().wheel_radius) *
                                   @motor_to_wheel_ratio
  # Hobbywing Xerun AXE540 R2, a 4-pole motor.
  @motor_pole_pairs 2

  @impl VmsCore.Vehicle
  def children do
    [
      # Controllers
      %{
        id: Vms.MainController,
        start: {
          OVCS.GenericController,
          :start_link,
          [
            %{
              process_name: Vms.MainController,
              control_digital_pins: true,
              control_other_pins: false,
              enabled_external_pwms: [0]
            }
          ]
        }
      },
      {OVCS.RosActuatorCommand.Steering, %{}},
      {OVCS.RosActuatorCommand.Throttle, %{}},
      {OVCS.RosActuatorCommand.Direction, %{}},
      # The planner-shaped command path: linear + angular velocity on
      # 0x2B1, converted to steering and throttle here against this
      # vehicle's own geometry. Started unconditionally — it emits
      # zeros until something publishes, and whether the drivetrain
      # *reads* it is the channel-5 switch's decision, below.
      # `steering_sign: -1` was measured on the servo: a REP-103
      # positive yaw rate (Nav2 turning left) drove this servo right, so
      # the sign is inverted to match the drivetrain's convention.
      {OVCS.RosVelocityCommand,
       Map.merge(
         Map.take(OvcsMini.geometry(), [:wheelbase, :steering_limit]),
         %{max_speed: @max_speed_m_s, steering_sign: -1}
       )},
      {OVCS.RadioControl.Steering,
       %{
         radio_control_channel: 1
       }},
      {OVCS.RadioControl.Throttle,
       %{
         radio_control_channel: 2
       }},
      # The hands' feel, one curve each, between the commander and the
      # manager. A velocity goes to the manager unshaped.
      {OVCS.InputCurve,
       %{
         process_name: Vms.RadioThrottleInputCurve,
         throttle_source: OVCS.RadioControl.Throttle,
         deadzone: @throttle_deadzone,
         expo: @throttle_expo
       }},
      {OVCS.InputCurve,
       %{
         process_name: Vms.TeleopThrottleInputCurve,
         throttle_source: OVCS.RosActuatorCommand.Throttle,
         deadzone: @throttle_deadzone,
         expo: @throttle_expo
       }},
      # Two switches, two questions. Channel 6 says who has authority,
      # channel 5 says which ROS node commands when ROS does — see
      # `Managers.ControlLevel`. Both only *request*; the manager
      # decides, which is the whole reason they route through it rather
      # than being read where the actuators are wired.
      #
      # This is the Mini transmitter's layout over ExpressLRS in MAVLink
      # link mode, which forces the Hybrid switch mode: sticks on 1 and
      # 2, switches from 5 up, 3 and 4 unused. Channel 5 is the link's
      # 2-position arm channel and cannot carry a middle position, so
      # the three-position level goes on 6 and the two-position
      # commander takes 5. docs/vehicle_parameterisation.md has the
      # layout of every vehicle.
      {OVCS.RadioControl.RequestedControlLevel,
       %{
         radio_control_channel: 6
       }},
      {OVCS.RadioControl.RequestedRosCommander,
       %{
         radio_control_channel: 5
       }},
      # The reverse button: its position is the requested direction,
      # which `Managers.Gear` turns into `:drive` or `:reverse` once the
      # truck is stopped and the trigger released.
      {OVCS.RadioControl.Direction,
       %{
         radio_control_channel: 7
       }},
      {Managers.ControlLevel,
       %{
         requested_control_level_source: OVCS.RadioControl.RequestedControlLevel,
         requested_ros_commander_source: OVCS.RadioControl.RequestedRosCommander,
         # No gear lever on an RC truck, the gear comes from the
         # direction below, and no pedals — so `:manual` has no inputs
         # at all, which makes it the useful safe position on the
         # switch rather than a gap. Every source nil means nothing
         # commands the vehicle.
         requested_gear_sources: %{manual: nil, radio: nil, ros: %{}},
         # A velocity carries its own sign, so the planner path needs
         # no direction — see 0x2B1. The radio and the gamepad select a
         # gear, and their throttle drives in it or brakes.
         requested_direction_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Direction,
           ros: %{teleop: OVCS.RosActuatorCommand.Direction, autonomous: nil}
         },
         requested_throttle_sources: %{
           manual: nil,
           radio: Vms.RadioThrottleInputCurve,
           ros: %{teleop: Vms.TeleopThrottleInputCurve, autonomous: OVCS.RosVelocityCommand}
         },
         requested_steering_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Steering,
           ros: %{teleop: OVCS.RosActuatorCommand.Steering, autonomous: OVCS.RosVelocityCommand}
         },
         # No brake pedal here, so the manual-brake override has no
         # input. Pulling the transmitter's throttle into reverse does
         # work: `RadioControl.Throttle` reports `:radio_breaking` on a
         # negative request, which drops `:ros` back to `:radio`. That
         # is the human takeover, and it works whichever ROS commander
         # was driving.
         manual_breaking_source: nil,
         radio_breaking_source: OVCS.RadioControl.Throttle,
         # Start in the safe position: nothing commands the vehicle
         # until the switch says otherwise.
         #
         # On the host bench that means nothing commands it at all:
         # `radio_control_bridge_config(:host)` declares no components,
         # so nothing emits 0x2A0/0x2A1, channel 6 stays at its default
         # 1000, and joystick input on 0x2B0/0x2B1 is discarded with no
         # log. Nothing emits the pulse counter frame either, so the
         # speed is unknown and the manager refuses every mode change
         # until one is synthesised. docs/vehicle_parameterisation.md,
         # "Driving on the host bench", has the frames for both.
         default_control_level: :manual,
         ready_to_drive_source: Vms,
         # The standstill gate on every mode change reads this; the
         # fused rotation reads exactly zero at rest.
         speed_source: OVCS.VehicleMotion
       }},
      # Drive or reverse from the selected direction source. No
      # ignition on the Mini, so no contact source.
      {Managers.Gear,
       %{
         selected_control_level_source: Managers.ControlLevel,
         ready_to_drive_source: Vms,
         speed_source: OVCS.VehicleMotion,
         contact_source: nil
       }},
      # The manager owns the choice now, so the drivetrain follows
      # whichever source it names rather than being wired to one
      # commander for the life of the process.
      {Traxxas.Steering,
       %{
         controller: Vms.MainController,
         external_pwm_id: 0,
         selected_control_level_source: Managers.ControlLevel
       }},
      # The traction motor, behind a VESC on `misc`.
      {Vesc.MotorController,
       %{
         process_name: Vms.Vesc,
         network: :misc,
         selected_control_level_source: Managers.ControlLevel,
         linear_sources: [OVCS.RosVelocityCommand],
         selected_gear_source: Managers.Gear,
         max_brake_current: @max_brake_current,
         max_rotation_per_minute: @max_motor_rotation_per_minute,
         pole_pairs: @motor_pole_pairs,
         max_throttle: @max_throttle,
         max_reverse: @max_reverse_throttle
       }},
      {OVCS.PulseRotationSensor,
       %{
         controller: Vms.MainController,
         pulses_per_revolution: @pulses_per_revolution
       }},
      # The motor's rotation: the VESC first, the spur sensor as its
      # cross-check and its fallback. Every rpm here is the motor's.
      {OVCS.RotationFusion,
       %{
         process_name: Vms.MotorRotation,
         sources: [
           %{source: Vms.Vesc, ratio: 1, signed: true, noise_rpm: 5},
           %{
             source: OVCS.PulseRotationSensor,
             ratio: @spur_teeth / @pinion_teeth,
             signed: false
           }
         ],
         direction_source: Vms.Vesc,
         # The VESC's minimum speed-loop rpm: where the planner drives.
         cross_check_from_rpm: 450,
         cross_check_tolerance: 0.1,
         # Past the spur sensor's decay after a hard stop.
         cross_check_hold_ms: 1_500
       }},
      # The vehicle's own motion, published on the bus for the
      # manager's standstill gate and emitted on 0x60B for the ROS
      # bridge's odometry. `steering_sign` must match
      # `RosVelocityCommand`'s so the reported angle converts back to
      # REP-103.
      {OVCS.VehicleMotion,
       %{
         rotation_source: Vms.MotorRotation,
         rotation_to_wheel_ratio: @motor_to_wheel_ratio,
         rotation_signed: true,
         wheel_radius: OvcsMini.geometry().wheel_radius,
         selected_control_level_source: Managers.ControlLevel,
         steering_limit: OvcsMini.geometry().steering_limit,
         steering_sign: 1
       }},
      {VmsCore.Status,
       %{
         ready_to_drive_source: Vms,
         vms_status_source: Vms
       }},
      # Vehicle
      {Vms, []}
    ]
  end
end
