defmodule VmsCore.Vehicles.OBD2.Composer.Dashboard.LiveDataPage do
  alias VmsCore.Vehicles.OBD2.Diagnostics

  def definition(order: order) do
    %{
      name: "Live data",
      icon: "ChartBarIcon",
      order: order,
      blocks: %{
        "engine" => %{
          order: 0,
          name: "Engine",
          type: "table",
          rows: [
            %{type: :metric, name: "RPM", module: Diagnostics, key: :rotation_per_minute},
            %{type: :metric, name: "Speed", module: Diagnostics, key: :speed, unit: "km/h"},
            %{type: :metric, name: "Throttle position", module: Diagnostics, key: :throttle_position, unit: "%"},
            %{type: :metric, name: "Engine load", module: Diagnostics, key: :engine_load, unit: "%"},
            %{type: :metric, name: "Mass air flow", module: Diagnostics, key: :mass_air_flow, unit: "g/s"}
          ]
        },
        "temperatures" => %{
          order: 1,
          name: "Temperatures",
          type: "table",
          rows: [
            %{type: :metric, name: "Coolant temperature", module: Diagnostics, key: :coolant_temperature, unit: "°C"},
            %{type: :metric, name: "Intake air temperature", module: Diagnostics, key: :intake_air_temperature, unit: "°C"},
            %{type: :metric, name: "Ambient air temperature", module: Diagnostics, key: :ambient_air_temperature, unit: "°C"},
            %{type: :metric, name: "Oil temperature", module: Diagnostics, key: :oil_temperature, unit: "°C"}
          ]
        },
        "electrical" => %{
          order: 2,
          name: "Electrical & Fuel",
          type: "table",
          rows: [
            %{type: :metric, name: "Control module voltage", module: Diagnostics, key: :control_module_voltage, unit: "V"},
            %{type: :metric, name: "Fuel level", module: Diagnostics, key: :fuel_level, unit: "%"}
          ]
        },
        "engine-chart" => %{
          order: 3,
          name: "Engine load & throttle",
          type: "lineChart",
          full_width: true,
          serie_max_size: 300,
          y_axis: [
            %{min: 0, max: 100, label: "%", series: [
              %{name: "Throttle", metric: %{module: Diagnostics, key: :throttle_position}},
              %{name: "Engine load", metric: %{module: Diagnostics, key: :engine_load}}
            ]}
          ]
        },
        "temperature-chart" => %{
          order: 4,
          name: "Temperatures over time",
          type: "lineChart",
          full_width: true,
          serie_max_size: 300,
          y_axis: [
            %{min: -40, max: 130, label: "°C", series: [
              %{name: "Coolant", metric: %{module: Diagnostics, key: :coolant_temperature}},
              %{name: "Intake air", metric: %{module: Diagnostics, key: :intake_air_temperature}},
              %{name: "Oil", metric: %{module: Diagnostics, key: :oil_temperature}}
            ]}
          ]
        }
      }
    }
  end
end
