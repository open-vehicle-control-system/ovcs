defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.BrakeBoosterPage do
  alias  VmsCore.Components.Bosch.IBoosterGen2

  def definition(order: order) do
    %{
      name: "Brake Booster",
      icon: "ExclamationCircleIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Status",
          type: "table",
          rows: [
            %{type: :metric, name: "Status", module: IBoosterGen2, key: :status},
            %{type: :metric, name: "Requested Throttle Source", module: IBoosterGen2, key: :requested_throttle_source},
            %{type: :metric, name: "Driver brake apply?", module: IBoosterGen2, key: :driver_brake_apply},
            %{type: :metric, name: "Internal State", module: IBoosterGen2, key: :internal_state},
            %{type: :metric, name: "Rod Position", module: IBoosterGen2, key: :rod_position, unit: "mm"},
            %{type: :metric, name: "Target Rod Position", module: IBoosterGen2, key: :rod_position_target, unit: "mm"},
            %{type: :metric, name: "Flow Rate", module: IBoosterGen2, key: :flow_rate, unit: "ml/s"},
            %{type: :metric, name: "Automatic Mode Enabled", module: IBoosterGen2, key: :automatic_mode_enabled},
            %{type: :metric, name: "Requested Braking", module: IBoosterGen2, key: :requested_braking, unit: "%"},
          ]
        },
        "pid-chart" => %{
          order: 1,
          name: "PID Chart",
          type: "lineChart",
          full_width: true,
          serie_max_size: 300,
          y_axis: [
            %{min: IBoosterGen2.min_rod_position(), max: IBoosterGen2.max_rod_position(), label: "mm", series: [
              %{name: "Rod Position", metric: %{module: IBoosterGen2, key: :rod_position}},
              %{name: "Target Rod Position", metric: %{module: IBoosterGen2, key: :rod_position_target}},
            ]},
            %{position: "right", min: 0, max: 1, label: "%", series: [
              %{name: "Requested Braking", metric: %{module: IBoosterGen2, key: :requested_braking}},
            ]}
          ]
        }
      }
    }
  end
end
