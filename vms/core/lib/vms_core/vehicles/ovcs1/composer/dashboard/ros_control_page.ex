defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.ROSControlPage do
  alias  VmsCore.Components.OVCS.ROSControl

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
            %{type: :metric, name: "Requested Direction", module: ROSControl.Direction, key: :requested_direction},
            %{type: :metric, name: "Requested Steering", module: ROSControl.Steering, key: :requested_steering},
            %{type: :metric, name: "Requested Throttle", module: ROSControl.Throttle, key: :requested_throttle}
          ]
        },
        "steering-and-throttle" => %{
          order: 1,
          name: "ROS Steering & Throttle",
          type: "lineChart",
          full_width: false,
          serie_max_size: 300,
          y_axis: [
            %{min: -1, max: 1, label: "%", series: [
              %{name: "Requested Steering", metric: %{module: ROSControl.Steering, key: :requested_steering}},
              %{name: "Requested Throttle", metric: %{module: ROSControl.Throttle, key: :requested_throttle}}
            ]}
          ]
        }
      }
    }
  end
end
