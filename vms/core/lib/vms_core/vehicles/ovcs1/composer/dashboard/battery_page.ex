defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.BatteryPage do
  alias VmsCore.Components.Evpt.Evpt23Charger
  alias VmsCore.Components.Orion.Bms2

  def definition(order: order) do
    %{
      name: "Battery",
      icon: "Battery50Icon",
      order: order,
      blocks: %{
        "bms-status" => %{
          order: 0,
          name: "BMS Status",
          type: "table",
          rows: [
            %{type: :metric, name: "Pack current", module: Bms2, key: :pack_current, unit: "A"},
            %{type: :metric, name: "Pack voltage", module: Bms2, key: :pack_voltage, unit: "V"},
            %{type: :metric, name: "Pack SOC", module: Bms2, key: :pack_state_of_charge, unit: "%"},
            %{type: :metric, name: "J1772 plug state", module: Bms2, key: :j1772_plug_state},
            %{type: :metric, name: "12V battery voltage", module: Bms2, key: :twelve_volt_battery_voltage, unit: "V"},
            %{type: :metric, name: "Pack lowest temperature", module: Bms2, key: :pack_lowest_temperature, unit: "°C"},
            %{type: :metric, name: "Pack highest temperature", module: Bms2, key: :pack_highest_temperature, unit: "°C"},
            %{type: :metric, name: "Pack average temperature", module: Bms2, key: :pack_average_temperature, unit: "°C"},
            %{type: :metric, name: "Is charging source enabled", module: Bms2, key: :is_charging_source_enabled},
            %{type: :metric, name: "Is ready source enabled", module: Bms2, key: :is_ready_source_enabled},
            %{type: :metric, name: "Charger safety relay enabled", module: Bms2, key: :charger_safety_relay_enabled},
            %{type: :metric, name: "Discharge relay enabled", module: Bms2, key: :discharge_relay_enabled},
            %{type: :metric, name: "Charge interlock enabled", module: Bms2, key: :charge_interlock_enabled},
            %{type: :metric, name: "Balancing active", module: Bms2, key: :balancing_active},
            %{type: :metric, name: "Malfunction indicator active", module: Bms2, key: :malfunction_indicator_active}
          ]
        },
        "charger-status" => %{
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
