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

  # Which ROS commander fills the `:autonomous` slot. Two exist — a
  # gamepad's normalised axes on 0x2B0/0x2B1, and a planner's velocity
  # on 0x3A0 — and they are different kinds of thing rather than two
  # versions of one, so the choice stays explicit.
  #
  # This no longer decides *whether* ROS drives the vehicle; the
  # transmitter's switch does, through `Managers.ControlLevel`. It only
  # decides which ROS path `:autonomous` listens to. `joy` stays the
  # default so existing behaviour is unchanged.
  defp drive_source do
    case System.get_env("OVCS_DRIVE_SOURCE", "joy") do
      "velocity" -> :velocity
      _joy -> :joy
    end
  end

  defp autonomous_steering_source do
    case drive_source() do
      :velocity -> OVCS.Ros2Control.Velocity
      :joy -> OVCS.ROSControl.Steering
    end
  end

  defp autonomous_throttle_source do
    case drive_source() do
      :velocity -> OVCS.Ros2Control.Velocity
      :joy -> OVCS.ROSControl.Throttle
    end
  end

  # A velocity carries its own sign, so the planner path needs no
  # separate direction signal — see 0x3A0.
  defp autonomous_direction_source do
    case drive_source() do
      :velocity -> nil
      :joy -> OVCS.ROSControl.Direction
    end
  end

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
      # zeros until something publishes, and which source the
      # drivetrain *reads* is decided below.
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
      # A three-position switch on channel 5 *requests* a control
      # level. The manager decides — a request is not authority, which
      # is the whole reason it routes through `Managers.ControlLevel`
      # rather than being read where the actuators are wired.
      {OVCS.RadioControl.RequestedControlLevel,
       %{
         radio_control_channel: 5
       }},
      {Managers.ControlLevel,
       %{
         requested_control_level_source: OVCS.RadioControl.RequestedControlLevel,
         # No gearbox on an RC truck, and no pedals — so `:manual` has
         # no inputs at all, which makes it the useful safe position on
         # the switch rather than a gap. Every source nil means nothing
         # commands the vehicle.
         requested_gear_sources: %{manual: nil, radio: nil, autonomous: nil},
         requested_direction_sources: %{
           manual: nil,
           radio: nil,
           autonomous: autonomous_direction_source()
         },
         requested_throttle_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Throttle,
           autonomous: autonomous_throttle_source()
         },
         requested_steering_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Steering,
           autonomous: autonomous_steering_source()
         },
         # No brake pedal here, so the manual-brake override has no
         # input. Pulling the transmitter's throttle into reverse does
         # work: `RadioControl.Throttle` reports `:radio_breaking` on a
         # negative request, which drops `:autonomous` back to
         # `:radio`. That is the human takeover.
         manual_breaking_source: nil,
         radio_breaking_source: OVCS.RadioControl.Throttle,
         # Start in the safe position: nothing commands the vehicle
         # until the switch says otherwise.
         default_control_level: :manual,
         ready_to_drive_source: Vms,
         # KNOWN GAP. The manager only allows a change into `:radio` or
         # `:autonomous` at a standstill, read from a `:speed`
         # broadcast. Nothing on Mini publishes one — `Traxxas.Motor`
         # reports `:raw_rotation_per_minute`, which is a raw
         # `analogRead()` sample rather than a rate, because the
         # controller firmware does no pulse counting yet.
         #
         # With no source the manager's speed stays at zero, so the
         # interlock is *permissive*: mode changes are allowed at any
         # speed. Not worse than today, where nothing arbitrates at
         # all, but not the intended behaviour either. Closing it
         # needs the hall sensor.
         speed_source: nil
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
         selected_control_level_source: Managers.ControlLevel
       }},
      {Traxxas.Motor,
       %{
         controller: Vms.MainController,
         rotation_per_minute_pin: 0
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
