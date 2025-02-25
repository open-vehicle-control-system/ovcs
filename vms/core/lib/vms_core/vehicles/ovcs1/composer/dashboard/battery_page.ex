defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.BatteryPage do
  alias VmsCore.Components.Nissan.LeafZE0.Charger

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
            %{type: :metric, name: "Charging State", module: Charger, key: :charging_state},
            %{type: :metric, name: "AC Voltage", module: Charger, key: :ac_voltage, unit: "V"},
            %{type: :metric, name: "Charge Power", module: Charger, key: :charge_power, unit: "kW"},
            %{type: :metric, name: "Maximum Charge Power", module: Charger, key: :maximum_charge_power, unit: "kW"}
          ]
        },
      }
    }
  end
end
