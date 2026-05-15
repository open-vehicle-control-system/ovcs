defmodule Ovcs1.Infotainment.Composer.Infotainment.Blocks.StatusGridBlock do
  alias Ovcs1.Infotainment

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
        %{module: Infotainment, key: :vms_computed_status, label: "Vehicle Management System"},
        %{module: Infotainment, key: :front_controler_computed_status, label: "Front Controler"},
        %{module: Infotainment, key: :rear_controller_computed_status, label: "Rear Controler"},
        %{module: Infotainment, key: :controls_controller_computed_status, label: "Controls Controler"},
        %{module: Infotainment, key: :bms_computed_status, label: "BMS"},
        %{module: Infotainment, key: :inverter_enabled, label: "Inverter enabled"},
        %{module: Infotainment, key: :main_negative_contactor_enabled, label: "Main Negative"},
        %{module: Infotainment, key: :main_positive_contactor_enabled, label: "Main Positive"},
        %{module: Infotainment, key: :precharge_contactor_enabled, label: "Precharge"}
      ]
    }
  end
end
