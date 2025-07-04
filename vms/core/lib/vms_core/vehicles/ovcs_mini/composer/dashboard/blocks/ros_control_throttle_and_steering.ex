defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard.Blocks.ROSControlThrottleAndSteeringBlock do
  alias  VmsCore.Components.OVCS.ROSControl

  def definition(order: order, full_width: full_width) do
    %{
      order: order,
      name: "ROS Steering & Throttle",
      type: "lineChart",
      full_width: full_width,
      serie_max_size: 300,
      y_axis: [
        %{min: -1, max: 1, label: "%", series: [
          %{name: "Requested Steering", metric: %{module: ROSControl.Steering, key: :requested_steering}},
          %{name: "Requested Throttle", metric: %{module: ROSControl.Throttle, key: :requested_throttle}}
        ]}
      ]
    }
  end
end
