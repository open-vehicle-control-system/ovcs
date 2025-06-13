defmodule VmsCore.Vehicles.OVCSMini.Composer do
  @moduledoc """
    Combine all the modules require to run the OVCS1 car
  """

  alias VmsCore.Components.{OVCS, Traxxas}
  alias VmsCore.{Vehicles, Vehicles.OVCSMini}

  defdelegate generic_controllers, to:  Vehicles.OVCSMini.Composer.GenericController
  defdelegate dashboard_configuration, to:  Vehicles.OVCSMini.Composer.Dashboard

  def children do
    [
      # Controllers
      %{
        id: OVCSMini.MainController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: OVCSMini.MainController,
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
        controller: OVCSMini.MainController,
        external_pwm_id: 0,
        requested_steering_source: OVCS.RadioControl.Steering
      }},
      {Traxxas.Throttle, %{
        controller: OVCSMini.MainController,
        external_pwm_id: 1,
        requested_throttle_source: OVCS.RadioControl.Throttle
      }},
      {VmsCore.Status, %{
        ready_to_drive_source: Vehicles.OVCSMini,
        vms_status_source: Vehicles.OVCSMini
      }},
      # Vehicle
      {Vehicles.OVCSMini, []},
    ]
  end
end
