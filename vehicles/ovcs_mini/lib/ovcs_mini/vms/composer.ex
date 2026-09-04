defmodule OvcsMini.Vms.Composer do
  @moduledoc """
    Combine all the modules required to run the OVCS Mini car
  """
  @behaviour VmsCore.Vehicle

  alias VmsCore.Components.{OVCS, Traxxas}
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

  # Which command path the drivetrain reads. Two exist — a joystick's
  # normalised axes on 0x2B0/0x2B1, and a planner's velocity on 0x3A0 —
  # and nothing arbitrates between them yet.
  #
  # `VmsCore.Managers.ControlLevel` is what should decide this, the way
  # it does on OVCS1: the transmitter requests a mode and brake input
  # forces a downgrade. Until that is wired here, an environment
  # variable makes the choice explicit and reversible rather than
  # hardcoded. `joy` stays the default so existing behaviour is
  # unchanged.
  defp drive_source do
    case System.get_env("OVCS_DRIVE_SOURCE", "joy") do
      "velocity" -> :velocity
      _joy -> :joy
    end
  end

  defp steering_source do
    case drive_source() do
      :velocity -> OVCS.Ros2Control.Velocity
      :joy -> OVCS.ROSControl.Steering
    end
  end

  defp throttle_source do
    case drive_source() do
      :velocity -> OVCS.Ros2Control.Velocity
      :joy -> OVCS.ROSControl.Throttle
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
      {Traxxas.Steering,
       %{
         controller: Vms.MainController,
         external_pwm_id: 0,
         requested_steering_source: steering_source()
       }},
      {Traxxas.Throttle,
       %{
         controller: Vms.MainController,
         external_pwm_id: 1,
         requested_throttle_source: throttle_source()
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
