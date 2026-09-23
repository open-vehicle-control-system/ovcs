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
  # speed loop holds for it, through the gearing below.
  @max_speed_m_s 0.5

  # Throttle feel for hands, see `Traxxas.Throttle` for what each one
  # does. It shapes the VESC's duty command; a velocity bypasses it.
  @throttle_deadzone Decimal.new("0.05")
  @throttle_expo Decimal.new("0.5")
  # Duty caps by hand, in drive and in reverse gear. 5% duty turned the
  # lifted wheels at about 1,550 motor rpm on a 15.7 V pack, about
  # 0.8 m/s through the gearing below, so 3% is about 0.5 m/s unloaded,
  # the planner's top speed. Duty is a fraction of the pack voltage: the
  # same cap is slower on a flatter pack.
  @throttle_max Decimal.new("0.03")
  @throttle_max_reverse Decimal.new("0.03")
  # Braking current at a full pull of the trigger. ESTIMATE: through the
  # motor's torque constant and the gearing, 10 A is about 9 N at the
  # tyres, a few m/s² on a truck this size. The VESC's own motor
  # current limits stay in force below it.
  @max_brake_current 10

  # Motor turns per wheel turn. Traxxas specifies 11.82:1 overall for
  # the stock gearing, which this truck runs: 13 pinion teeth on a 54
  # tooth spur, both counted. The pinion stage was also measured through
  # the VESC and the spur sensor at 5% duty: 1,548 motor rpm against 366
  # spur rpm, 4.2, 54/13 within the sensor's 6 rpm resolution.
  @motor_to_wheel_ratio 11.82
  @pinion_teeth 13
  @spur_teeth 54

  # The trigger magnet sits in the spur gear: one magnet, one pulse per
  # spur turn. What is left of the overall ratio past the pinion stage
  # is the transmission, 2.85 spur turns per wheel turn. The sensor only
  # knows the first constant; the second is the vehicle's kinematics and
  # goes to `VehicleMotion`.
  @pulses_per_revolution 1
  @spur_to_wheel_ratio @motor_to_wheel_ratio * @pinion_teeth / @spur_teeth

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
           radio: OVCS.RadioControl.Throttle,
           ros: %{teleop: OVCS.RosActuatorCommand.Throttle, autonomous: OVCS.RosVelocityCommand}
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
         # The standstill gate on every mode change reads this. It is
         # exactly zero once the hall sensor has been quiet for two
         # seconds, and the kinematics only scale what counts as
         # moving, so an estimate there does not weaken the gate.
         speed_source: OVCS.VehicleMotion
       }},
      # Drive or reverse from the selected direction source, shifted
      # only below 1 km/h with the trigger released. No ignition on the
      # Mini, so no contact source.
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
      # The traction motor, behind a VESC on `misc`. With no source it
      # releases the motor. A hand drives in the selected gear through
      # the feel curve, and pulling the trigger back always brakes; a
      # velocity gets the VESC's speed loop.
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
         # The trigger at rest drifts by up to 20 counts of 500, and
         # the joystick node's own dead zone is the same 5%. Matches
         # `RadioControl.Throttle`'s braking threshold, so a trigger
         # that reads as braking also reads as a request here.
         deadzone: @throttle_deadzone,
         # Half way between linear and the full square: enough
         # flattening for fine control at low speed without pushing
         # the edge of motion a third of the way along the trigger.
         expo: @throttle_expo,
         max_throttle: @throttle_max,
         max_reverse: @throttle_max_reverse
       }},
      {OVCS.PulseRotationSensor,
       %{
         controller: Vms.MainController,
         pulses_per_revolution: @pulses_per_revolution
       }},
      # The vehicle's own motion: the spur's rotation through the
      # gearing and the wheel size gives the speed, published on the
      # bus for the manager's standstill gate and emitted on 0x60B for
      # the ROS bridge's odometry. The hall sensor cannot know the
      # direction, so the sign follows the direction the VESC is
      # driven in: the request's sign would flip the speed while a
      # moving truck brakes. `steering_sign` must match
      # `RosVelocityCommand`'s so the reported angle converts back to
      # REP-103.
      #
      # The spur sensor rather than the motor: it is the reading
      # independent of the VESC's gearing constants, and it reads
      # exactly zero at rest, which the manager's standstill gate
      # needs. The VESC reports a stray erpm or two on a stopped motor.
      {OVCS.VehicleMotion,
       %{
         rotation_source: OVCS.PulseRotationSensor,
         rotation_to_wheel_ratio: @spur_to_wheel_ratio,
         rotation_signed: false,
         direction_source: Vms.Vesc,
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
