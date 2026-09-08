defmodule OvcsMini.Vms.Composer.Dashboard.DashboardPage do
  alias OvcsMini.Vms
  alias VmsCore.Components.OVCS
  alias VmsCore.Managers
  alias VmsCore.Status

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "HomeIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Ready to drive",
          type: "table",
          rows: [
            %{
              type: :action,
              name: "Reset Status",
              input_type: :button,
              module: Status,
              action: "reset_status"
            },
            %{type: :metric, name: "VMS Status", module: Vms, key: :vms_status},
            %{type: :metric, name: "OVCS Mini ready", module: Vms, key: :ready_to_drive},
            %{
              type: :metric,
              name: "Main Controller Alive",
              module: Vms.MainController,
              key: :is_alive
            }
          ]
        },
        "drivetrain" => %{
          order: 1,
          name: "Drivetrain",
          type: "table",
          rows: [
            %{
              type: :metric,
              name: "Selected Control Level",
              module: Managers.ControlLevel,
              key: :selected_control_level
            },
            %{
              type: :metric,
              name: "Selected ROS Commander",
              module: Managers.ControlLevel,
              key: :selected_ros_commander
            },
            %{
              type: :metric,
              name: "Control Level Forced",
              module: Managers.ControlLevel,
              key: :control_level_forced
            },
            %{
              type: :metric,
              name: "Speed",
              module: OVCS.PulseSpeedSensor,
              key: :speed,
              unit: "km/h"
            },
            %{
              type: :metric,
              name: "Wheel RPM",
              module: OVCS.PulseSpeedSensor,
              key: :wheel_rotation_per_minute
            }
          ]
        },
        "speed-and-rpm" => %{
          order: 2,
          name: "Speed & RPM",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{
              min: 0,
              max: 30,
              label: "km/h",
              series: [%{name: "Speed", metric: %{module: OVCS.PulseSpeedSensor, key: :speed}}]
            },
            %{
              position: "right",
              min: 0,
              # A wheel turning at the estimated top speed, 5 m/s on a
              # 0.0548 m wheel, does a little under 900 rpm.
              max: 1_000,
              label: "RPM",
              series: [
                %{
                  name: "Wheel RPM",
                  metric: %{module: OVCS.PulseSpeedSensor, key: :wheel_rotation_per_minute}
                }
              ]
            }
          ]
        }
      }
    }
  end
end
