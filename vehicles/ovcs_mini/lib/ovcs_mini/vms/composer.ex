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

  # The hall sensor's magnet turns with the motor side of the drivetrain,
  # so wheel speed needs the ratio down to the wheel. ESTIMATE: one
  # pulse per turn, and a stock Slash 4x4 drivetrain of roughly 10.5:1
  # (2.72 transmission, 50/13 spur to pinion). Only the product of the
  # two matters, and it is measured directly: roll the vehicle one wheel
  # turn and count the pulses on `0x709`.
  @pulses_per_revolution 1
  @gear_ratio 10.5

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
      {OVCS.ROSControl.Steering, %{}},
      {OVCS.ROSControl.Throttle, %{}},
      {OVCS.ROSControl.Direction, %{}},
      # The planner-shaped command path: linear + angular velocity on
      # 0x3A0, converted to steering and throttle here against this
      # vehicle's own geometry. Started unconditionally — it emits
      # zeros until something publishes, and whether the drivetrain
      # *reads* it is the channel-5 switch's decision, below.
      {OVCS.Ros2Control.Velocity,
       Map.merge(
         Map.take(OvcsMini.geometry(), [:wheelbase, :steering_limit]),
         %{max_speed: @max_speed_m_s}
       )},
      {OVCS.RadioControl.Steering,
       %{
         radio_control_channel: 1
       }},
      {OVCS.RadioControl.Throttle,
       %{
         radio_control_channel: 2
       }},
      # Two switches, two questions. Channel 3 says who has authority,
      # channel 5 says which ROS node commands when ROS does — see
      # `Managers.ControlLevel`. Both only *request*; the manager
      # decides, which is the whole reason they route through it rather
      # than being read where the actuators are wired.
      #
      # Channel 3 for authority, with 4 left free for direction, is the
      # OVCS1 convention — so a transmitter set up for one vehicle
      # reads the same way on the other.
      {OVCS.RadioControl.RequestedControlLevel,
       %{
         radio_control_channel: 3
       }},
      {OVCS.RadioControl.RequestedRosCommander,
       %{
         radio_control_channel: 5
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
         # no separate direction signal — see 0x3A0. The gamepad path
         # does, because its throttle axis is unsigned.
         requested_direction_sources: %{
           manual: nil,
           radio: nil,
           ros: %{teleop: OVCS.ROSControl.Direction, autonomous: nil}
         },
         requested_throttle_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Throttle,
           ros: %{teleop: OVCS.ROSControl.Throttle, autonomous: OVCS.Ros2Control.Velocity}
         },
         requested_steering_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Steering,
           ros: %{teleop: OVCS.ROSControl.Steering, autonomous: OVCS.Ros2Control.Velocity}
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
         # so nothing emits 0x2A0/0x2A1, channel 3 stays at its default
         # 1000, and joystick input on 0x2B0/0x2B1 is discarded with no
         # log. Synthesise the switches with `cansend` --
         # docs/vehicle_parameterisation.md, "Driving on the host
         # bench", has the frames.
         default_control_level: :manual,
         ready_to_drive_source: Vms,
         # The standstill gate on every mode change reads this. It is
         # exactly zero once the hall sensor has been quiet for a
         # second, and the gear ratio above only scales what counts as
         # moving, so an estimate there does not weaken the gate.
         speed_source: Traxxas.Motor
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
         # it bypasses the joystick feel curve.
         linear_sources: [OVCS.Ros2Control.Velocity]
       }},
      {Traxxas.Motor,
       %{
         controller: Vms.MainController,
         pulse_pin: 0,
         pulses_per_revolution: @pulses_per_revolution,
         gear_ratio: @gear_ratio,
         wheel_radius: OvcsMini.geometry().wheel_radius
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
