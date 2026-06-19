defmodule Ovcs1.Vms.Composer.Dashboard.SteeringColumnPage do
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
        "pid-tuning" => %{
          order: 1,
          name: "PID Tuning",
          type: "table",
          rows: [
            %{type: :action, name: "Kp", hint: "Proportional — strength of immediate correction", input_type: :number, step: "0.01", input_name: "Set", module: SteeringColumn, action: "set_pid_parameter", extra_parameters: %{"parameter" => "kp"}, status_metric_key: :kp},
            %{type: :action, name: "Ki", hint: "Integral — removes steady-state error", input_type: :number, step: "0.005", input_name: "Set", module: SteeringColumn, action: "set_pid_parameter", extra_parameters: %{"parameter" => "ki"}, status_metric_key: :ki},
            %{type: :action, name: "Kd", hint: "Derivative — damps overshoot (amplifies noise)", input_type: :number, step: "0.005", input_name: "Set", module: SteeringColumn, action: "set_pid_parameter", extra_parameters: %{"parameter" => "kd"}, status_metric_key: :kd},
          ]
        },
        "input-filter" => %{
          order: 2,
          name: "Input Filter",
          type: "table",
          rows: [
            %{type: :action, name: "Deadband", hint: "Ignores input changes smaller than this", input_type: :number, step: "0.005", input_name: "Set", module: SteeringColumn, action: "set_filter_parameter", extra_parameters: %{"parameter" => "deadband"}, status_metric_key: :input_deadband},
            %{type: :action, name: "Alpha", hint: "Smoothing 0–1 — lower is smoother but slower", input_type: :number, step: "0.05", input_name: "Set", module: SteeringColumn, action: "set_filter_parameter", extra_parameters: %{"parameter" => "alpha"}, status_metric_key: :input_alpha},
          ]
        },
        "pid-chart" => %{
          order: 3,
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
