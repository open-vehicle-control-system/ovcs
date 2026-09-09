defmodule OvcsMini.Vms.Composer do
  @moduledoc """
    Combine all the modules required to run the OVCS Mini car
  """
  @behaviour VmsCore.Vehicle

  alias VmsCore.Components.{OVCS, Traxxas}
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
  def default_can_mapping(:host), do: "ovcs:vcan0"
  def default_can_mapping(:target), do: "ovcs:spi0.0"

  # Full throttle in m/s. Not geometry — a property of the motor and
  # gearing, not a measured dimension of the chassis. ESTIMATE: a stock
  # Slash 4x4 does roughly 30 mph, and the simulated model is capped at
  # 13 m/s, but nothing has measured this one under load.
  @max_speed_m_s 5.0

  # Throttle feel, see `Traxxas.Throttle` for what each one does.
  @throttle_deadzone Decimal.new("0.05")
  @throttle_expo Decimal.new("0.5")
  @throttle_start_offset Decimal.new("0.06")

  # The trigger magnet sits in the spur gear, so wheel speed needs the
  # ratio from the spur gear to the wheels: the Slash 4x4 transmission's
  # fixed 2.72:1. The pinion does not enter into it. One magnet, one
  # pulse per spur turn. Confirmed on the bench: 14 pulses over 10 wheel
  # revolutions back-driven through one wheel, which the open
  # differential halves, gives ~2.8 pulses per wheel turn — 2.72 within
  # the +/-1 count noise. Only the product of the two constants matters.
  @pulses_per_revolution 1
  @gear_ratio 2.72

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
              enabled_external_pwms: [0, 1]
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
      # Started so the value is published; no actuator on the Mini
      # reads a direction, since reverse is a negative throttle here.
      # Named as the radio source below so a drivetrain that consumes
      # direction can be wired without touching the manager.
      {OVCS.RadioControl.Direction,
       %{
         radio_control_channel: 7
       }},
      {Managers.ControlLevel,
       %{
         requested_control_level_source: OVCS.RadioControl.RequestedControlLevel,
         requested_ros_commander_source: OVCS.RadioControl.RequestedRosCommander,
         # No gearbox on an RC truck, and no pedals — so `:manual` has
         # no inputs at all, which makes it the useful safe position on
         # the switch rather than a gap. Every source nil means nothing
         # commands the vehicle.
         requested_gear_sources: %{manual: nil, radio: nil, ros: %{}},
         # A velocity carries its own sign, so the planner path needs
         # no separate direction signal — see 0x2B1. The gamepad path
         # does, because its throttle axis is unsigned.
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
         # seconds, and the gear ratio above only scales what counts as
         # moving, so an estimate there does not weaken the gate.
         speed_source: OVCS.PulseSpeedSensor
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
      {Traxxas.Throttle,
       %{
         controller: Vms.MainController,
         external_pwm_id: 1,
         selected_control_level_source: Managers.ControlLevel,
         # A velocity is a physical quantity, not a hand on a trigger:
         # it bypasses the dead zone, the feel curve and the start
         # offset below.
         linear_sources: [OVCS.RosVelocityCommand],
         # The trigger at rest drifts by up to 20 counts of 500, and
         # the joystick node's own dead zone is the same 5%. Matches
         # `RadioControl.Throttle`'s braking threshold, so a trigger
         # that reads as braking also reads as a request here.
         deadzone: @throttle_deadzone,
         # Half way between linear and the full square: enough
         # flattening for fine control at low speed without pushing
         # the edge of motion a third of the way along the trigger.
         expo: @throttle_expo,
         # ESTIMATE: the throttle output at which the wheels first
         # move. The radio control page shows the request, not the
         # output, so the reading has to be run through the curve in
         # force when it was taken. Too low only wastes a little
         # travel; too high makes the first touch a jump, so it starts
         # conservative.
         start_offset: @throttle_start_offset
       }},
      {OVCS.PulseSpeedSensor,
       %{
         controller: Vms.MainController,
         pulses_per_revolution: @pulses_per_revolution,
         gear_ratio: @gear_ratio,
         wheel_radius: OvcsMini.geometry().wheel_radius
       }},
      # The vehicle's own motion on 0x60B, for the ROS bridge's
      # odometry. The sign of the speed follows the selected throttle
      # request, since the hall sensor cannot know the direction, and
      # `steering_sign` must match `RosVelocityCommand`'s so the
      # reported angle converts back to REP-103.
      {OVCS.VehicleMotion,
       %{
         speed_source: OVCS.PulseSpeedSensor,
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
