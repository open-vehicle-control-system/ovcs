defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.ThrottlePedalPage do
  alias VmsCore.Components.OVCS.ThrottlePedal
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard.Blocks

  def definition(order: order) do
    %{
      name: "Throttle Pedal",
      icon: "ChevronUpDownIcon",
      order: order,
      blocks: %{
        "calibration" => %{
          order: 0,
          name: "Calibration",
          type: "calibration",
          values: [%{
              name: "Calibrate throttle boundaries",
              type: "boundaries",
              module: ThrottlePedal,
              status_metric_key: :throttle_calibration_status
            }
          ]
        },
        "status" => %{
          order: 1,
          name: "Status",
          type: "table",
          metrics: [
            %{name: "Requested Throttle", module: ThrottlePedal, key: :requested_throttle},
            %{name: "Raw Throttle A", module: ThrottlePedal, key: :raw_throttle_a},
            %{name: "Raw Throttle B", module: ThrottlePedal, key: :raw_throttle_b},
            %{name: "Low Raw Throttle A", module: ThrottlePedal, key: :low_raw_throttle_a},
            %{name: "Low Raw Throttle B", module: ThrottlePedal, key: :low_raw_throttle_b},
            %{name: "High Raw Throttle A", module: ThrottlePedal, key: :high_raw_throttle_a},
            %{name: "High Raw Throttle B", module: ThrottlePedal, key: :high_raw_throttle_b},
            %{name: "Raw Max Throttle", module: ThrottlePedal, key: :raw_max_throttle},
          ]
        },
        "throttle-chart" => Blocks.ThrottleChart.definition(order: 1, full_width: true),
      }
    }
  end
end
