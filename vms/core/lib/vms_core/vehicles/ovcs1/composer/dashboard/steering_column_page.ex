defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.SteeringColumnPage do
  alias VmsCore.Components.OVCS.SteeringColumn

  def definition(order: order) do
    %{
      name: "Steering Column",
      icon: "ArrowPathIcon",
      order: order,
      blocks: %{
        "calibration" => %{
          order: 0,
          name: "Calibration",
          type: "calibration",
          values: [
            %{
              name: "Save steering wheel 0°",
              type: "initial",
              module: SteeringColumn
            }
          ]
        },
        "status" => %{
          order: 0,
          name: "Status",
          type: "table",
          metrics: [
            %{name: "Angle", module: SteeringColumn, key: :angle, unit: "°"},
            %{name: "Desired Angle", module: SteeringColumn, key: :desired_angle, unit: "°"},
            %{name: "Angular Speed", module: SteeringColumn, key: :angular_speed, unit: "°/s"},
            %{name: "Trimming Valid", module: SteeringColumn, key: :trimming_valid},
            %{name: "Calibration Valid", module: SteeringColumn, key: :calibration_valid},
            %{name: "Sensor Ready", module: SteeringColumn, key: :sensor_ready},
            %{name: "Automatic Mode Enabled", module: SteeringColumn, key: :automatic_mode_enabled},
          ]
        },
        "pid-chart" => %{
          order: 1,
          name: "PID Chart",
          type: "lineChart",
          full_width: true,
          serie_max_size: 300,
          y_axis: [
            %{min: -780, max: 780, label: "°", series: [
              %{name: "Angle", metric: %{module: SteeringColumn, key: :angle}},
              %{name: "Desired Angle", metric: %{module: SteeringColumn, key: :desired_angle}}
            ]},
            %{position: "right", min: 0, max: 2500, label: "°/s", series: [
              %{name: "Angular Speed", metric: %{module: SteeringColumn, key: :angular_speed}}
            ]}
          ]
        }
      }
    }
  end
end
