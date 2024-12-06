defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.SteeringColumnPage do
  alias VmsCore.Components.OVCS.SteeringColumn

  def definition(order: order) do
    %{
      name: "Steering Column",
      icon: "ArrowPathIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Status",
          type: "table",
          rows: [
            %{type: :action, name: "Save steering wheel 0°", input_type: :button, input_name: "Save", module: SteeringColumn, action: "calibrate_angle_0"},
            %{type: :metric, name: "Angle", module: SteeringColumn, key: :angle, unit: "°"},
            %{type: :metric, name: "Desired Angle", module: SteeringColumn, key: :desired_angle, unit: "°"},
            %{type: :metric, name: "Angular Speed", module: SteeringColumn, key: :angular_speed, unit: "°/s"},
            %{type: :metric, name: "Trimming Valid", module: SteeringColumn, key: :trimming_valid},
            %{type: :metric, name: "Calibration Valid", module: SteeringColumn, key: :calibration_valid},
            %{type: :metric, name: "Sensor Ready", module: SteeringColumn, key: :sensor_ready},
            %{type: :metric, name: "Automatic Mode Enabled", module: SteeringColumn, key: :automatic_mode_enabled},
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
