defmodule Obd2.Vms.Composer.Dashboard.DashboardPage do
  alias Obd2.Vms.Diagnostics

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "HomeIcon",
      order: order,
      blocks: %{
        "vehicle-information" => %{
          order: 0,
          name: "Vehicle Snapshot",
          type: "table",
          rows: [
            %{type: :metric, name: "VIN",  module: Diagnostics, key: :vin},
            %{type: :metric, name: "ECU name", module: Diagnostics, key: :ecu_name},
            %{type: :metric, name: "Speed", module: Diagnostics, key: :speed, unit: "km/h"},
            %{type: :metric, name: "RPM", module: Diagnostics, key: :rotation_per_minute},
            %{type: :metric, name: "Throttle", module: Diagnostics, key: :throttle_position, unit: "%"},
            %{type: :metric, name: "Engine load", module: Diagnostics, key: :engine_load, unit: "%"},
            %{type: :metric, name: "Coolant temperature", module: Diagnostics, key: :coolant_temperature, unit: "°C"},
            %{type: :metric, name: "Battery voltage", module: Diagnostics, key: :control_module_voltage, unit: "V"},
            %{type: :metric, name: "Stored DTC count", module: Diagnostics, key: :stored_dtc_count},
            %{type: :metric, name: "Pending DTC count", module: Diagnostics, key: :pending_dtc_count},
            %{type: :metric, name: "Permanent DTC count", module: Diagnostics, key: :permanent_dtc_count},
            %{type: :metric, name: "UDS DTC count", module: Diagnostics, key: :uds_dtc_count},
            %{type: :metric, name: "Supported PID count", module: Diagnostics, key: :supported_pid_count}
          ]
        },
        "rpm-speed" => %{
          order: 5,
          name: "RPM & Speed",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: 0, max: 8000, label: "RPM", series: [
              %{name: "RPM", metric: %{module: Diagnostics, key: :rotation_per_minute}}
            ]},
            %{position: "right", min: 0, max: 200, label: "km/h", series: [
              %{name: "Speed", metric: %{module: Diagnostics, key: :speed}}
            ]}
          ]
        }
      }
    }
  end
end
