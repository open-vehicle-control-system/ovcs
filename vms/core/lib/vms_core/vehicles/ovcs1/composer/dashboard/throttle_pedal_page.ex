defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.ThrottlePedalPage do
  alias VmsCore.Components.OVCS.ThrottlePedal
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard.Blocks

  def definition(order: order) do
    %{
      name: "Throttle Pedal",
      icon: "ChevronUpDownIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 1,
          name: "Status",
          type: "table",
          rows: [
            %{type: :action, name: "Calibrate throttle boundaries", input_type: :toggle, input_name: "Set", module: ThrottlePedal, action: "calibrate_boundaries", status_metric_key: :throttle_calibration_ongoing},
            %{type: :metric, name: "Requested Throttle", module: ThrottlePedal, key: :requested_throttle},
            %{type: :metric, name: "Raw Throttle A", module: ThrottlePedal, key: :raw_throttle_a},
            %{type: :metric, name: "Raw Throttle B", module: ThrottlePedal, key: :raw_throttle_b},
            %{type: :metric, name: "Low Raw Throttle A", module: ThrottlePedal, key: :low_raw_throttle_a},
            %{type: :metric, name: "Low Raw Throttle B", module: ThrottlePedal, key: :low_raw_throttle_b},
            %{type: :metric, name: "High Raw Throttle A", module: ThrottlePedal, key: :high_raw_throttle_a},
            %{type: :metric, name: "High Raw Throttle B", module: ThrottlePedal, key: :high_raw_throttle_b},
            %{type: :metric, name: "Raw Max Throttle", module: ThrottlePedal, key: :raw_max_throttle},
          ]
        },
        "throttle-chart" => Blocks.ThrottleChart.definition(order: 1, full_width: true),
      }
    }
  end
end
