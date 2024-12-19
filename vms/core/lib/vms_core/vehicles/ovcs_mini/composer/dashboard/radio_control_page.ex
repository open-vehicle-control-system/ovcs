defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard.RadioControlPage do
  alias  VmsCore.Components.OVCS.RadioControl
  alias VmsCore.Vehicles.OVCSMini.Composer.Dashboard.Blocks.RadioControlThrottleAndSteeringBlock

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
            %{type: :metric, name: "Requested Control Level", module: RadioControl.RequestedControlLevel, key: :requested_control_level},
            %{type: :metric, name: "Requested Gear", module: RadioControl.Gear, key: :requested_gear},
            %{type: :metric, name: "Requested Steering", module: RadioControl.Steering, key: :requested_steering},
            %{type: :metric, name: "Requested Throttle", module: RadioControl.Throttle, key: :requested_throttle}
          ]
        },
        "steering-and-throttle" => RadioControlThrottleAndSteeringBlock.definition(order: 1, full_width: false)
      }
    }
  end
end
