defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard.Blocks.RadioControlThrottleAndSteeringBlock do
  alias  VmsCore.Components.OVCS.RadioControl

  def definition(order: order, full_width: full_width) do
    %{
      order: order,
      name: "Steering & Throttle",
      type: "lineChart",
      full_width: full_width,
      serie_max_size: 300,
      y_axis: [
        %{min: -1, max: 1, label: "%", series: [
          %{name: "Requested Steering", metric: %{module: RadioControl.Steering, key: :requested_steering}},
          %{name: "Requested Throttle", metric: %{module: RadioControl.Throttle, key: :requested_throttle}}
        ]}
      ]
    }
  end
end
