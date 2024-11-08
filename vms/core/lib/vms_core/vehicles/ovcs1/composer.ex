defmodule VmsCore.Vehicles.OVCS1.Composer do
  @moduledoc """
    Combine all the modules require to run the OVCS1 car
  """
  alias VmsCore.Components.{
    Bosch,
    Nissan.LeafZE0,
    OVCS,
    Volkswagen.Polo9N
  }
  alias VmsCore.{Managers, Vehicles}

  def children do
    [
      # Controllers
      %{
        id: OVCS.FrontController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: OVCS.FrontController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: []
          }]
        }
      },
      %{
        id: OVCS.ControlsController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: OVCS.ControlsController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: [0]
          }]
        }
      },
      %{
        id: OVCS.RearController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: OVCS.RearController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: []
          }]
        }
      },
      # %{
      #   id: OVCS.TestController,
      #   start: {
      #     OVCS.GenericController,
      #     :start_link, [%{
      #       process_name: OVCS.TestController,
      #       control_digital_pins: true,
      #       control_other_pins: true,
      #       enabled_external_pwms: [0,1,2,3]
      #     }]
      #   }
      # },

      # VwPolo
      {Polo9N.Dashboard, %{
        contact_source: Polo9N.IgnitionLock,
        rotation_per_minute_source: LeafZE0.Inverter
      }},
      {Polo9N.ABS, %{
        contact_source: Polo9N.IgnitionLock,
        rotation_per_minute_source: LeafZE0.Inverter
      }},
      {Polo9N.PassengerCompartment, []},
      {Polo9N.IgnitionLock, []},
      {Polo9N.PowerSteeringPump, %{
        selected_gear_source: Managers.Gear
      }},

      # NissanLeaf
      {LeafZE0.Inverter, %{
        selected_gear_source: Managers.Gear,
        requested_throttle_source: OVCS.ThrottlePedal,
        contact_source: Polo9N.IgnitionLock,
        controller: OVCS.FrontController,
        power_relay_pin: 3
      }},

      #Bosch
      {Bosch.IBoosterGen2, %{
        contact_source: Polo9N.IgnitionLock,
        controller: OVCS.FrontController,
        power_relay_pin: 5
      }},
      {Bosch.LWS, []},

      # OVCS
      {Managers.Gear, %{
        requested_gear_source: OVCS.Infotainment,
        ready_to_drive_source: Vehicles.OVCS1,
        speed_source: Polo9N.ABS,
        requested_throttle_source: OVCS.ThrottlePedal
      }},
      {OVCS.ThrottlePedal, %{
        controller: OVCS.ControlsController,
        throttle_a_pin: 0,
        throttle_b_pin: 1
      }},
      {Vehicles.OVCS1.OVCSCANForwarder, %{
        passenger_compartement_source: Polo9N.PassengerCompartment,
        speed_source: Polo9N.ABS
      }},
      {OVCS.Infotainment, []},
      {OVCS.HighVoltageContactors, %{
        contact_source: Polo9N.IgnitionLock,
        inverter_output_voltage_source: LeafZE0.Inverter,
        required_precharge_output_voltage: 300,
        controller: OVCS.RearController,
        main_negative_relay_pin: 3,
        main_positive_relay_pin: 4,
        precharge_relay_pin: 5
      }},
      {OVCS.SteeringColumn, %{
        power_relay_controller: OVCS.FrontController,
        power_relay_pin: 6,
        actuation_controller: OVCS.ControlsController,
        direction_pin: 1,
        external_pwm_id: 0
      }},
      {VmsCore.Status, %{
        ready_to_drive_source: Vehicles.OVCS1,
        vms_status_source: Vehicles.OVCS1
      }},
      # Vehicle
      {Vehicles.OVCS1, []},
    ]
  end

  def generic_controllers do
    %{
      OVCS.FrontController => %{
        "controller_id" => 0,
        "digital_pin0" => "disabled",
        "digital_pin1" => "disabled",
        "digital_pin2" => "disabled",
        "digital_pin3" => "read_write",
        "digital_pin4" => "read_write",
        "digital_pin5" => "read_write",
        "digital_pin6" => "read_write",
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
      },
      OVCS.RearController => %{
        "controller_id" => 1,
        "digital_pin0" => "disabled",
        "digital_pin1" => "disabled",
        "digital_pin2" => "disabled",
        "digital_pin3" => "read_write",
        "digital_pin4" => "read_write",
        "digital_pin5" => "read_write",
        "digital_pin6" => "read_write",
        "digital_pin7" => "read_write",
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
      },
      OVCS.ControlsController => %{
        "controller_id" => 2,
        "digital_pin0" => "disabled",
        "digital_pin1" => "disabled",
        "digital_pin2" => "disabled",
        "digital_pin3" => "read_write",
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
        "pwm_pin0" => "enabled",
        "pwm_pin1" => "disabled",
        "pwm_pin2" => "disabled",
        "dac_pin0" => "disabled",
        "analog_pin0" => "enabled",
        "analog_pin1" => "enabled",
        "analog_pin2" => "disabled"
      },
      # OVCS.TestController => %{
      #   "controller_id" => 3,
      #   "digital_pin0" => "read_write",
      #   "digital_pin1" => "read_write",
      #   "digital_pin2" => "read_write",
      #   "digital_pin3" => "read_write",
      #   "digital_pin4" => "read_write",
      #   "digital_pin5" => "read_write",
      #   "digital_pin6" => "read_write",
      #   "digital_pin7" => "read_write",
      #   "digital_pin8" => "read_write",
      #   "digital_pin9" => "read_write",
      #   "digital_pin10" => "read_write",
      #   "digital_pin11" => "read_write",
      #   "digital_pin12" => "read_write",
      #   "digital_pin13" => "read_write",
      #   "digital_pin14" => "read_write",
      #   "digital_pin15" => "read_write",
      #   "digital_pin16" => "read_write",
      #   "digital_pin17" => "read_write",
      #   "digital_pin18" => "read_write",
      #   "pwm_pin0" => "enabled",
      #   "pwm_pin1" => "enabled",
      #   "pwm_pin2" => "enabled",
      #   "dac_pin0" => "enabled",
      #   "analog_pin0" => "enabled",
      #   "analog_pin1" => "enabled",
      #   "analog_pin2" => "enabled"
      # }
    }
  end
end
