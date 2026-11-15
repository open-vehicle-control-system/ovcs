defmodule Ovcs1.Vms.Composer do
  @moduledoc """
    Combine all the modules required to run the OVCS1 car
  """
  @behaviour VmsCore.Vehicle

  @impl VmsCore.Vehicle
  defdelegate generic_controllers, to: Ovcs1.Vms.Composer.GenericController
  @impl VmsCore.Vehicle
  defdelegate dashboard_configuration, to: Ovcs1.Vms.Composer.Dashboard

  @impl VmsCore.Vehicle
  def can_config_otp_app, do: :ovcs1
  @impl VmsCore.Vehicle
  def can_config_path, do: "can/vms.yml"

  @impl VmsCore.Vehicle
  def default_can_mapping(:host),
    do: "ovcs:vcan0,leaf_drive:vcan1,polo_drive:vcan2,orion_bms:vcan3,misc:vcan4"

  def default_can_mapping(:target),
    do: "ovcs:spi0.0,leaf_drive:spi0.1,polo_drive:spi1.0,orion_bms:spi1.1,misc:spi1.2"

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

  @inverter_drive_max_torque_nm 100
  @inverter_reverse_max_torque_nm 100

  @doc "The Leaf inverter's torque request at full throttle in `:drive`, in newton-metres."
  def inverter_drive_max_torque_nm, do: @inverter_drive_max_torque_nm

  @doc "The Leaf inverter's torque request at full throttle in `:reverse`, in newton-metres."
  def inverter_reverse_max_torque_nm, do: @inverter_reverse_max_torque_nm

  @wiring %{
    abs: %{network: :polo_drive},
    ignition_lock: %{network: :polo_drive},
    inverter: %{network: :leaf_drive, controller: Vms.RearController, power_relay_pin: 7},
    high_voltage_contactors: %{
      controller: Vms.RearController,
      main_negative_relay_pin: 3,
      main_positive_relay_pin: 4,
      precharge_relay_pin: 5
    },
    ibooster: %{network: :misc, controller: Vms.FrontController, power_relay_pin: 5},
    steering_column: %{
      network: :misc,
      power_relay_controller: Vms.FrontController,
      power_relay_pin: 6,
      actuation_controller: Vms.ControlsController,
      direction_pin: 1,
      external_pwm_id: 0
    },
    radio_control_channels: %{steering: 1, throttle: 2, requested_control_level: 3, direction: 4}
  }

  @doc """
  Where the VMS reaches the hardware it drives: networks, controllers,
  pins and radio channels. What simulated hardware needs to be wired
  like this one.
  """
  def wiring, do: @wiring

  @impl VmsCore.Vehicle
  def children do
    [
      # Controllers
      %{
        id: Vms.FrontController,
        start: {
          OVCS.GenericController,
          :start_link,
          [
            %{
              process_name: Vms.FrontController,
              control_digital_pins: true,
              control_other_pins: false,
              enabled_external_pwms: []
            }
          ]
        }
      },
      %{
        id: Vms.ControlsController,
        start: {
          OVCS.GenericController,
          :start_link,
          [
            %{
              process_name: Vms.ControlsController,
              control_digital_pins: true,
              control_other_pins: false,
              enabled_external_pwms: [0]
            }
          ]
        }
      },
      %{
        id: Vms.RearController,
        start: {
          OVCS.GenericController,
          :start_link,
          [
            %{
              process_name: Vms.RearController,
              control_digital_pins: true,
              control_other_pins: false,
              enabled_external_pwms: []
            }
          ]
        }
      },

      # VwPolo
      {Polo9N.Dashboard,
       %{
         network: :polo_drive,
         contact_source: Polo9N.IgnitionLock,
         rotation_per_minute_source: LeafAZE0.Inverter
       }},
      {Polo9N.ABS,
       Map.merge(@wiring.abs, %{
         contact_source: Polo9N.IgnitionLock,
         rotation_per_minute_source: LeafAZE0.Inverter
       })},
      {Polo9N.PassengerCompartment, %{network: :polo_drive}},
      {Polo9N.IgnitionLock, @wiring.ignition_lock},
      {Polo9N.PowerSteeringPump,
       %{
         network: :misc,
         selected_gear_source: Managers.Gear
       }},
      {Polo9N.FakeOilPressureSensor,
       %{
         controller: Vms.FrontController,
         relay_pin: 3,
         rotation_per_minute_source: LeafAZE0.Inverter
       }},

      # NissanLeaf
      {LeafAZE0.Inverter,
       Map.merge(@wiring.inverter, %{
         selected_control_level_source: Managers.ControlLevel,
         selected_gear_source: Managers.Gear,
         contact_source: Polo9N.IgnitionLock,
         drive_max_torque_nm: @inverter_drive_max_torque_nm,
         reverse_max_torque_nm: @inverter_reverse_max_torque_nm
       })},

      # Orion
      {Orion.Bms2,
       %{
         network: :orion_bms,
         controller: Vms.RearController,
         ready_relay_pin: 6
       }},

      # EVPT
      {Evpt.Evpt23Charger, %{network: :orion_bms}},

      # Bosch
      {Bosch.IBoosterGen2,
       Map.merge(@wiring.ibooster, %{
         selected_control_level_source: Managers.ControlLevel,
         contact_source: Polo9N.IgnitionLock
       })},

      # OVCS
      {OVCS.RadioControl.Steering,
       %{radio_control_channel: @wiring.radio_control_channels.steering}},
      {OVCS.RadioControl.Throttle,
       %{radio_control_channel: @wiring.radio_control_channels.throttle}},
      {OVCS.RadioControl.RequestedControlLevel,
       %{radio_control_channel: @wiring.radio_control_channels.requested_control_level}},
      {OVCS.RadioControl.Direction,
       %{radio_control_channel: @wiring.radio_control_channels.direction}},
      {OVCS.RosActuatorCommand.Steering, %{}},
      {OVCS.RosActuatorCommand.Throttle, %{}},
      {OVCS.RosActuatorCommand.Direction, %{}},
      {Managers.ControlLevel,
       %{
         requested_control_level_source: OVCS.RadioControl.RequestedControlLevel,
         # `:ros` is keyed by commander because a gamepad and a planner
         # are different commanders on the same authority level. OVCS1
         # has no planner path yet and no second switch, so only
         # `:teleop` is populated; the manager pins the commander to
         # `:teleop` when no source is configured.
         requested_gear_sources: %{
           manual: OVCS.Infotainment,
           radio: nil,
           ros: %{teleop: nil}
         },
         requested_direction_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Direction,
           ros: %{teleop: OVCS.RosActuatorCommand.Direction}
         },
         requested_throttle_sources: %{
           manual: OVCS.ThrottlePedal,
           radio: OVCS.RadioControl.Throttle,
           ros: %{teleop: OVCS.RosActuatorCommand.Throttle}
         },
         requested_steering_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Steering,
           ros: %{teleop: OVCS.RosActuatorCommand.Steering}
         },
         # The iBooster brakes on these sources' negative throttle.
         requested_braking_sources: %{
           manual: nil,
           radio: OVCS.RadioControl.Throttle,
           ros: %{teleop: OVCS.RosActuatorCommand.Throttle}
         },
         manual_braking_source: Bosch.IBoosterGen2,
         radio_braking_source: OVCS.RadioControl.Throttle,
         default_control_level: :manual,
         ready_to_drive_source: Vms,
         speed_source: Polo9N.ABS
       }},
      {Managers.Gear,
       %{
         selected_control_level_source: Managers.ControlLevel,
         ready_to_drive_source: Vms,
         speed_source: Polo9N.ABS,
         contact_source: Polo9N.IgnitionLock
       }},
      {OVCS.ThrottlePedal,
       %{
         controller: Vms.ControlsController,
         throttle_a_pin: 0,
         throttle_b_pin: 1,
         cross_check_tolerance: "0.1",
         cross_check_hold_ms: 100
       }},
      {Vms.OVCSCANForwarder,
       %{
         passenger_compartement_source: Polo9N.PassengerCompartment,
         speed_source: Polo9N.ABS
       }},
      {OVCS.Infotainment, []},
      {OVCS.HighVoltageContactors,
       Map.merge(@wiring.high_voltage_contactors, %{
         contact_source: Polo9N.IgnitionLock,
         inverter_output_voltage_source: LeafAZE0.Inverter,
         required_precharge_output_voltage_v: 300
       })},
      {OVCS.SteeringColumn,
       Map.merge(@wiring.steering_column, %{
         selected_control_level_source: Managers.ControlLevel,
         max_steering_angle_deg: 400
       })},
      {OVCS.WaterPump,
       %{
         controller: Vms.FrontController,
         power_relay_pin: 4,
         selected_gear_source: Managers.Gear
       }},
      {VmsCore.Status,
       %{
         ready_to_drive_source: Vms,
         vms_status_source: Vms,
         bms_status_source: Orion.Bms2
       }},
      {VmsCore.Components.OVCS.Status,
       %{
         bms_status_source: Orion.Bms2
       }},
      # Vehicle
      {Vms, []}
    ]
  end
end
