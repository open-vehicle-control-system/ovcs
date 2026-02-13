defmodule InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment.Blocks.StatusGridBlock do
  alias InfotainmentCore.Vehicles.OVCS1

  def definition(order: order, column: column, row: row, columns: columns, rows: rows) do
    %{
      order: order,
      name: "System Status",
      type: "statusGrid",
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      metrics: [
        %{module: OVCS1, key: :vms_computed_status, label: "Vehicle Management System"},
        %{module: OVCS1, key: :front_controler_computed_status, label: "Front Controler"},
        %{module: OVCS1, key: :rear_controller_computed_status, label: "Rear Controler"},
        %{module: OVCS1, key: :controls_controller_computed_status, label: "Controls Controler"},
        %{module: OVCS1, key: :bms_computed_status, label: "BMS"},
        %{module: OVCS1, key: :inverter_enabled, label: "Inverter enabled"},
        %{module: OVCS1, key: :main_negative_contactor_enabled, label: "Main Negative"},
        %{module: OVCS1, key: :main_positive_contactor_enabled, label: "Main Positive"},
        %{module: OVCS1, key: :precharge_contactor_enabled, label: "Precharge"}
      ]
    }
  end
end
