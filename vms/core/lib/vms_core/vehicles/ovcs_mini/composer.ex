defmodule VmsCore.Vehicles.OVCSMini.Composer do
  @moduledoc """
    Combine all the modules require to run the OVCS1 car
  """
  alias VmsCore.Components.OVCS
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
            control_other_pins: true
          }]
        }
      },
      # OVCS
      # {Managers.Gear, %{
      #   requested_gear_source: ,
      #   ready_to_drive_source: ,
      #   speed_source: ,
      #   requested_throttle_source:
      # }},
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
        "digital_pin0" => "read_write",
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
        "digital_pin19" => "disabled",
        "digital_pin20" => "disabled",
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
