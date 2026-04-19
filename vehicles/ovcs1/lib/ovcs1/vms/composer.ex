defmodule Ovcs1.Vms.Composer do
  @moduledoc """
    Combine all the modules required to run the OVCS1 car
  """
  @behaviour VmsCore.Vehicle

  @impl VmsCore.Vehicle
  defdelegate generic_controllers, to:  Ovcs1.Vms.Composer.GenericController
  @impl VmsCore.Vehicle
  defdelegate dashboard_configuration, to:  Ovcs1.Vms.Composer.Dashboard

  @impl VmsCore.Vehicle
  def can_config_otp_app, do: :ovcs1
  @impl VmsCore.Vehicle
  def can_config_path, do: "can/vms.yml"

  @impl VmsCore.Vehicle
  def default_can_mapping(:host), do: "ovcs:vcan0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4"
  def default_can_mapping(:target), do: "ovcs:spi0.0,leaf_drive:spi0.1,polo_drive:spi1.0,orion_bms:spi1.1,misc:spi1.2"

  alias VmsCore.Components.{
    Bosch,
    Nissan.LeafAZE0,
    OVCS,
    Volkswagen.Polo9N,
    Orion,
    Evpt
  }
  alias VmsCore.Managers
  alias Ovcs1.Vms

  @impl VmsCore.Vehicle
  def children do
    [
      # Controllers
      %{
        id: Vms.FrontController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: Vms.FrontController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: []
          }]
        }
      },
      %{
        id: Vms.ControlsController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: Vms.ControlsController,
            control_digital_pins: true,
            control_other_pins: false,
            enabled_external_pwms: [0]
          }]
        }
      },
      %{
        id: Vms.RearController,
        start: {
          OVCS.GenericController,
          :start_link, [%{
            process_name: Vms.RearController,
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
      {Polo9N.FakeOilPressureSensor, %{
        controller: Vms.FrontController,
        relay_pin: 3,
        rotation_per_minute_source: LeafAZE0.Inverter
      }},

      # NissanLeaf
      {LeafAZE0.Inverter, %{
        selected_control_level_source: Managers.ControlLevel,
        selected_gear_source: Managers.Gear,
        contact_source: Polo9N.IgnitionLock,
        controller: Vms.RearController,
        power_relay_pin: 7
      }},

      # Orion
      {Orion.Bms2, %{
        controller: Vms.RearController,
        ready_relay_pin: 6
      }},

      #EVPT
      {Evpt.Evpt23Charger, %{}},

      #Bosch
      {Bosch.IBoosterGen2, %{
        selected_control_level_source: Managers.ControlLevel,
        contact_source: Polo9N.IgnitionLock,
        controller: Vms.FrontController,
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
      {OVCS.RadioControl.Direction, %{
        radio_control_channel: 6
      }},
      {OVCS.ROSControl.Steering, %{}},
      {OVCS.ROSControl.Throttle, %{}},
      {OVCS.ROSControl.Direction, %{}},
      {Managers.ControlLevel, %{
        requested_control_level_source: OVCS.RadioControl.RequestedControlLevel,
        requested_gear_sources: %{
          manual: OVCS.Infotainment,
          radio: nil,
          autonomous: nil
        },
        requested_direction_sources: %{
          manual: nil,
          radio: OVCS.RadioControl.Direction,
          autonomous: ROSControl.Direction
        },
        requested_throttle_sources: %{
          manual: OVCS.ThrottlePedal,
          radio: OVCS.RadioControl.Throttle,
          autonomous: ROSControl.Throttle
        },
        requested_steering_sources: %{
          manual: nil,
          radio: OVCS.RadioControl.Steering,
          autonomous: ROSControl.Steering
        },
        manual_breaking_source: Bosch.IBoosterGen2,
        radio_breaking_source: OVCS.RadioControl.Throttle,
        default_control_level: :manual,
        ready_to_drive_source: Vms,
        speed_source: Polo9N.ABS,
      }},
      {Managers.Gear, %{
        selected_control_level_source: Managers.ControlLevel,
        ready_to_drive_source: Vms,
        speed_source: Polo9N.ABS,
        contact_source: Polo9N.IgnitionLock
      }},
      {OVCS.ThrottlePedal, %{
        controller: Vms.ControlsController,
        throttle_a_pin: 0,
        throttle_b_pin: 1
      }},
      {Vms.OVCSCANForwarder, %{
        passenger_compartement_source: Polo9N.PassengerCompartment,
        speed_source: Polo9N.ABS
      }},
      {OVCS.Infotainment, []},
      {OVCS.HighVoltageContactors, %{
        contact_source: Polo9N.IgnitionLock,
        inverter_output_voltage_source: LeafAZE0.Inverter,
        required_precharge_output_voltage: 300,
        controller: Vms.RearController,
        main_negative_relay_pin: 3,
        main_positive_relay_pin: 4,
        precharge_relay_pin: 5
      }},
      {OVCS.SteeringColumn, %{
        selected_control_level_source: Managers.ControlLevel,
        power_relay_controller: Vms.FrontController,
        power_relay_pin: 6,
        actuation_controller: Vms.ControlsController,
        direction_pin: 1,
        external_pwm_id: 0
      }},
      {OVCS.WaterPump, %{
        controller:  Vms.FrontController,
        power_relay_pin: 4,
        selected_gear_source: Managers.Gear
      }},

      {VmsCore.Status, %{
        ready_to_drive_source: Vms,
        vms_status_source: Vms,
        bms_status_source: Orion.Bms2
      }},
      {VmsCore.Components.OVCS.Status, %{
        bms_status_source: Orion.Bms2
      }},
      # Vehicle
      {Vms, []},
    ]
  end
end
