defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.ThrottlePage do
  alias VmsCore.Components.OVCS.ThrottlePedal
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard.Blocks

  def definition do
    %{
      name: "Throttle",
      icon: "ChevronUpDownIcon",
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
            %{name: "Raw Max Throttle", module: ThrottlePedal, key: :raw_max_throttle},
            %{name: "Low Raw Throttle A", module: ThrottlePedal, key: :low_raw_throttle_a},
            %{name: "Low Raw Throttle B", module: ThrottlePedal, key: :low_raw_throttle_b},
            %{name: "High Raw Throttle A", module: ThrottlePedal, key: :high_raw_throttle_a},
            %{name: "High Raw Throttle B", module: ThrottlePedal, key: :high_raw_throttle_b},
            %{name: "Raw Throttle A", module: ThrottlePedal, key: :raw_throttle_a},
            %{name: "Raw Throttle B", module: ThrottlePedal, key: :raw_throttle_b},
            %{name: "Requested Throttle", module: ThrottlePedal, key: :requested_throttle},
          ]
        },
        "throttle-chart" => Blocks.ThrottleChart.definition(order: 1)
      }
    }
  end
end
