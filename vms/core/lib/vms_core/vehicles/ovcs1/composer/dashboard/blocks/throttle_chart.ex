defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.Blocks.ThrottleChart do
  alias VmsCore.Components.OVCS.ThrottlePedal

  def definition([order: order]) do
    %{
      order: order,
      name: "Throttle",
      type: "lineChart",
      serie_max_size: 300,
      y_axis: [
        %{min: 0, max: ThrottlePedal.raw_max_throttle(), label: "Raw", series: [
          %{name: "Throttle A", metric: %{module: ThrottlePedal, key: :raw_throttle_a}},
          %{name: "Throttle B", metric: %{module: ThrottlePedal, key: :raw_throttle_b}}
        ]},
        %{position: "right", min: 0, max: 1, label: "Computed", series: [
          %{name: "Computed Throttle", metric: %{module: ThrottlePedal, key: :requested_throttle}}
        ]}
      ]
    }
  end
end
