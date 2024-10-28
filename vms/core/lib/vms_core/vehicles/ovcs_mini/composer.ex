defmodule VmsCore.Vehicles.OVCSMini.Composer do
  @moduledoc """
    Combine all the modules require to run the OVCS1 car
  """
  alias VmsCore.Components.{OVCS, Traxxas}
  alias VmsCore.{Vehicles}

  def children do
    [
      # Controllers
      %{
        id: OVCS.MainController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: OVCS.MainController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: [0, 1]
          }]
        }
      },
      {OVCS.RadioControl.Steering, %{
        radio_control_channel: 4
      }},
      {OVCS.RadioControl.Throttle, %{
        radio_control_channel: 3
      }},
      {Traxxas.Steering, %{
        controller: OVCS.MainController,
        external_pwm_id: 0,
        requested_steering_source: OVCS.RadioControl.Steering
      }},
      {Traxxas.Throttle, %{
        controller: OVCS.MainController,
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

  def generic_controllers do
    %{
      OVCS.MainController => %{
        "controller_id" => 0,
        "digital_pin0" => "disabled",
        "digital_pin1" => "disabled",
        "digital_pin2" => "disabled",
        "digital_pin3" => "disabled",
        "digital_pin4" => "disabled",
        "digital_pin5" => "disabled",
        "digital_pin6" => "disabled",
        "digital_pin7" => "disabled",
        "digital_pin8" => "disabled",
        "digital_pin9" => "disabled",
        "digital_pin10" => "disabled",
        "digital_pin11" => "disabled",
        "digital_pin12" => "disabled",
        "digital_pin13" => "disabled",
        "digital_pin14" => "disabled",
        "digital_pin15" => "disabled",
        "digital_pin16" => "disabled",
        "digital_pin17" => "disabled",
        "digital_pin18" => "disabled",
        "pwm_pin0" => "disabled",
        "pwm_pin1" => "disabled",
        "pwm_pin2" => "disabled",
        "dac_pin0" => "disabled",
        "analog_pin0" => "disabled",
        "analog_pin1" => "disabled",
        "analog_pin2" => "disabled"
      }
    }
  end
end
