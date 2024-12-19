defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.RadioControlPage do
  alias  VmsCore.Components.OVCS.RadioControl

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
        "pid-chart" => %{
          order: 1,
          name: "Steering & Throttle",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: -1, max: 1, label: "%", series: [
              %{name: "Requested Steering", metric: %{module: RadioControl.Steering, key: :requested_steering}},
              %{name: "Requested Throttle", metric: %{module: RadioControl.Throttle, key: :requested_throttle}}
            ]}
          ]
        }
      }
    }
  end
end
