defmodule VmsCore.Vehicles.OVCS1.Composer do
  @moduledoc """
    Combine all the modules required to run the OVCS1 car
  """
  defdelegate generic_controllers, to:  VmsCore.Vehicles.OVCS1.Composer.GenericController
  defdelegate dashboard_configuration, to:  VmsCore.Vehicles.OVCS1.Composer.Dashboard

  alias VmsCore.Components.{
    Bosch,
    Nissan.LeafAZE0,
    OVCS,
    Volkswagen.Polo9N,
    Orion,
    Evpt
  }
  alias VmsCore.{Managers, Vehicles, Vehicles.OVCS1}

  def children do
    [
      # Controllers
      %{
        id: OVCS1.FrontController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: OVCS1.FrontController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: []
          }]
        }
      },
      %{
        id: OVCS1.ControlsController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: OVCS1.ControlsController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: [0]
          }]
        }
      },
      %{
        id: OVCS1.RearController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: OVCS1.RearController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: []
          }]
        }
      },

      # VwPolo
      {Polo9N.Dashboard, %{
        contact_source: Polo9N.IgnitionLock,
        rotation_per_minute_source: LeafAZE0.Inverter
      }},
      {Polo9N.ABS, %{
        contact_source: Polo9N.IgnitionLock,
        rotation_per_minute_source: LeafAZE0.Inverter
      }},
      {Polo9N.PassengerCompartment, []},
      {Polo9N.IgnitionLock, []},
      {Polo9N.PowerSteeringPump, %{
        selected_gear_source: Managers.Gear
      }},

      # NissanLeaf
      {LeafAZE0.Inverter, %{
        selected_control_level_source: Managers.ControlLevel,
        selected_gear_source: Managers.Gear,
        contact_source: Polo9N.IgnitionLock,
        controller: OVCS1.RearController,
        power_relay_pin: 7
      }},

      # Orion
      {Orion.Bms2, %{
        ac_input_voltage_source: LeafAZE0.Charger
      }},

      #EVPT
      {Evpt.Evpt23Charger, %{}},

      #Bosch
      {Bosch.IBoosterGen2, %{
        selected_control_level_source: Managers.ControlLevel,
        contact_source: Polo9N.IgnitionLock,
        controller: OVCS1.FrontController,
        power_relay_pin: 5
      }},

      # OVCS
      {OVCS.RadioControl.Steering, %{
        radio_control_channel: 1
      }},
      {OVCS.RadioControl.Throttle, %{
        radio_control_channel: 2
      }},
      {OVCS.RadioControl.RequestedControlLevel, %{
        radio_control_channel: 5
      }},
      {OVCS.RadioControl.Gear, %{
        radio_control_channel: 6
      }},
      {Managers.ControlLevel, %{
        requested_control_level_source: OVCS.RadioControl.RequestedControlLevel,
        requested_gear_sources: %{
          manual: OVCS.Infotainment,
          radio: OVCS.RadioControl.Gear
        },
        requested_throttle_sources: %{
          manual: OVCS.ThrottlePedal,
          radio: OVCS.RadioControl.Throttle
        },
        requested_steering_sources: %{
          manual: nil,
          radio: OVCS.RadioControl.Steering
        },
        manual_driver_brake_apply_source: Bosch.IBoosterGen2,
        default_control_level: :manual,
        ready_to_drive_source: Vehicles.OVCS1,
        contact_source: Polo9N.IgnitionLock
      }},
      {Managers.Gear, %{
        selected_control_level_source: Managers.ControlLevel,
        ready_to_drive_source: Vehicles.OVCS1,
        speed_source: Polo9N.ABS,
        contact_source: Polo9N.IgnitionLock
      }},
      {OVCS.ThrottlePedal, %{
        controller: OVCS1.ControlsController,
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
        inverter_output_voltage_source: LeafAZE0.Inverter,
        required_precharge_output_voltage: 300,
        controller: OVCS1.RearController,
        main_negative_relay_pin: 3,
        main_positive_relay_pin: 4,
        precharge_relay_pin: 5
      }},
      {OVCS.SteeringColumn, %{
        selected_control_level_source: Managers.ControlLevel,
        power_relay_controller: OVCS1.FrontController,
        power_relay_pin: 6,
        actuation_controller: OVCS1.ControlsController,
        direction_pin: 1,
        external_pwm_id: 0
      }},
      {VmsCore.Status, %{
        ready_to_drive_source: Vehicles.OVCS1,
        vms_status_source: Vehicles.OVCS1
      }},
      {VmsCore.Components.OVCS.Status, %{
        bms_status_source: Orion.Bms2
      }},
      # Vehicle
      {Vehicles.OVCS1, []},
    ]
  end
end
