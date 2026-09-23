defmodule OvcsMini.Vms.Composer.Dashboard.RadioControlPage do
  alias VmsCore.Components.OVCS.RadioControl
  alias OvcsMini.Vms.Composer.Dashboard.Blocks.RadioControlThrottleAndSteeringBlock

  def definition(order: order) do
    %{
      name: "Radio Control",
      icon: "WifiIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Status",
          type: "table",
          rows: [
            %{
              type: :metric,
              name: "Requested Control Level",
              module: RadioControl.RequestedControlLevel,
              key: :requested_control_level
            },
            %{
              type: :metric,
              name: "Requested ROS Commander",
              module: RadioControl.RequestedRosCommander,
              key: :requested_ros_commander
            },
            %{
              type: :metric,
              name: "Requested Direction",
              module: RadioControl.Direction,
              key: :requested_direction
            },
            %{
              type: :metric,
              name: "Requested Steering",
              module: RadioControl.Steering,
              key: :requested_steering
            },
            %{
              type: :metric,
              name: "Requested Throttle",
              module: RadioControl.Throttle,
              key: :requested_throttle
            }
          ]
        },
        "steering-and-throttle" =>
          RadioControlThrottleAndSteeringBlock.definition(order: 1, full_width: false)
      }
    }
  end
end
