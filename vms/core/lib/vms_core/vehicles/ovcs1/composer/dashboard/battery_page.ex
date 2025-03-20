defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.BatteryPage do
  alias VmsCore.Components.Evpt.Evpt23Charger

  def definition(order: order) do
    %{
      name: "Battery",
      icon: "Battery50Icon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Charger Status",
          type: "table",
          rows: [
            %{type: :metric, name: "Output voltage", module: Evpt23Charger, key: :output_voltage, unit: "V"},
            %{type: :metric, name: "Output current", module: Evpt23Charger, key: :output_current, unit: "A"},
            %{type: :metric, name: "CAN failure", module: Evpt23Charger, key: :communication_timeout_failure},
            %{type: :metric, name: "Battery disconnected or reversed", module: Evpt23Charger, key: :communication_timeout_failure},
            %{type: :metric, name: "AC voltage failure", module: Evpt23Charger, key: :battery_disconnected_or_reverse_connection_protection_enabled},
            %{type: :metric, name: "Charger over temp. failure", module: Evpt23Charger, key: :charger_over_temperature_protection_enabled},
            %{type: :metric, name: "Hardware failure", module: Evpt23Charger, key: :hardware_failure}
          ]
        },
      }
    }
  end
end
