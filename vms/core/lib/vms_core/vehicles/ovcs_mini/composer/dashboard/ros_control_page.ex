defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard.ROSControlPage do
  alias  VmsCore.Components.OVCS.ROSControl
  alias VmsCore.Vehicles.OVCSMini.Composer.Dashboard.Blocks.ROSControlThrottleAndSteeringBlock

  def definition(order: order) do
    %{
      name: "ROS Control",
      icon: "CpuChipIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Status",
          type: "table",
          rows: [
            %{type: :metric, name: "Requested Steering", module: ROSControl.Steering, key: :requested_steering},
            %{type: :metric, name: "Requested Throttle", module: ROSControl.Throttle, key: :requested_throttle}
          ]
        },
        "steering-and-throttle" => ROSControlThrottleAndSteeringBlock.definition(order: 1, full_width: false)
      }
    }
  end
end
