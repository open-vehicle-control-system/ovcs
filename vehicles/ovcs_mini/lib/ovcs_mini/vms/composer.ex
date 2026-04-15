defmodule OvcsMini.Vms.Composer do
  @moduledoc """
    Combine all the modules require to run the OVCS1 car
  """
  @behaviour VmsCore.Vehicle

  alias VmsCore.Components.{OVCS, Traxxas}
  alias OvcsMini.Vms

  @impl VmsCore.Vehicle
  defdelegate generic_controllers, to:  OvcsMini.Vms.Composer.GenericController
  @impl VmsCore.Vehicle
  defdelegate dashboard_configuration, to:  OvcsMini.Vms.Composer.Dashboard

  @impl VmsCore.Vehicle
  def can_config_otp_app, do: :ovcs_mini
  @impl VmsCore.Vehicle
  def can_config_path, do: "can/vms.yml"

  @impl VmsCore.Vehicle
  def children do
    [
      # Controllers
      %{
        id: Vms.MainController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: Vms.MainController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: [0, 1]
          }]
        }
      },
      {OVCS.ROSControl.Steering, %{}},
      {OVCS.ROSControl.Throttle, %{}},
      {OVCS.ROSControl.Direction, %{}},
      {OVCS.RadioControl.Steering, %{
        radio_control_channel: 1
      }},
      {OVCS.RadioControl.Throttle, %{
        radio_control_channel: 2
      }},
      {Traxxas.Steering, %{
        controller: Vms.MainController,
        external_pwm_id: 0,
        requested_steering_source: OVCS.ROSControl.Steering
      }},
      {Traxxas.Throttle, %{
        controller: Vms.MainController,
        external_pwm_id: 1,
        requested_throttle_source: OVCS.ROSControl.Throttle
      }},
      {Traxxas.Motor, %{
        controller: Vms.MainController,
        rotation_per_minute_pin: 0,
      }},
      {VmsCore.Status, %{
        ready_to_drive_source: Vms,
        vms_status_source: Vms
      }},
      # Vehicle
      {Vms, []},
    ]
  end
end
