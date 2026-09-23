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
            %{type: :metric, name: "OVCS Mini ready", module: Vms, key: :ready_to_drive}
          ]
        },
        "control-level" => %{
          order: 1,
          name: "Control Level",
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
              min: -10,
              max: 10,
              label: "km/h",
              series: [%{name: "Speed", metric: %{module: OVCS.VehicleMotion, key: :speed}}]
            },
            %{
              position: "right",
              min: 0,
              # 10 km/h on a 0.0548 m wheel is a little under 500 rpm.
              max: 500,
              label: "RPM",
              series: [
                %{
                  name: "Wheel RPM",
                  metric: %{module: OVCS.VehicleMotion, key: :wheel_rotation_per_minute}
                }
              ]
            }
          ]
        }
      }
    }
  end
end
