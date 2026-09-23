defmodule OvcsMini.Vms.Composer.Dashboard.DrivetrainPage do
  alias OvcsMini.Vms
  alias VmsCore.Components.OVCS
  alias VmsCore.Managers

  def definition(order: order) do
    %{
      name: "Drivetrain",
      icon: "CogIcon",
      order: order,
      blocks: %{
        "gear" => %{
          order: 0,
          name: "Gear",
          type: "table",
          rows: [
            %{
              type: :metric,
              name: "Selected Gear",
              module: Managers.Gear,
              key: :selected_gear
            }
          ]
        },
        "motor-controller" => %{
          order: 1,
          name: "Motor Controller (VESC)",
          type: "table",
          rows: [
            %{type: :metric, name: "Command", module: Vms.Vesc, key: :command},
            %{type: :metric, name: "Throttle", module: Vms.Vesc, key: :throttle},
            %{type: :metric, name: "Brake Current", module: Vms.Vesc, key: :brake_current},
            %{
              type: :metric,
              name: "Motor RPM",
              module: Vms.Vesc,
              key: :rotation_per_minute
            },
            %{type: :metric, name: "Direction", module: Vms.Vesc, key: :direction},
            %{
              type: :metric,
              name: "Motor Current",
              module: Vms.Vesc,
              key: :motor_current
            },
            %{
              type: :metric,
              name: "Battery Voltage",
              module: Vms.Vesc,
              key: :input_voltage
            }
          ]
        },
        "motor-rotation" => %{
          order: 2,
          name: "Motor Rotation",
          type: "table",
          rows: [
            %{
              type: :metric,
              name: "Motor RPM",
              module: Vms.MotorRotation,
              key: :rotation_per_minute
            },
            %{
              type: :metric,
              name: "Active Source",
              module: Vms.MotorRotation,
              key: :active_source
            },
            %{
              type: :metric,
              name: "Cross-check Gap",
              module: Vms.MotorRotation,
              key: :cross_check_gap
            },
            %{
              type: :metric,
              name: "Cross-check Fault",
              module: Vms.MotorRotation,
              key: :cross_check_fault
            }
          ]
        },
        "vehicle-motion" => %{
          order: 3,
          name: "Vehicle Motion",
          type: "table",
          rows: [
            %{
              type: :metric,
              name: "Speed",
              module: OVCS.VehicleMotion,
              key: :speed
            },
            %{
              type: :metric,
              name: "Wheel RPM",
              module: OVCS.VehicleMotion,
              key: :wheel_rotation_per_minute
            }
          ]
        },
        "spur-sensor" => %{
          order: 4,
          name: "Spur Sensor",
          type: "table",
          rows: [
            %{
              type: :metric,
              name: "Spur RPM",
              module: OVCS.PulseRotationSensor,
              key: :rotation_per_minute
            }
          ]
        }
      }
    }
  end
end
