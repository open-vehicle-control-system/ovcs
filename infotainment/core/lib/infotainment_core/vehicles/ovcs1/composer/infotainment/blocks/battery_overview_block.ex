defmodule InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment.Blocks.BatteryOverviewBlock do
  alias InfotainmentCore.Vehicles.OVCS1

  def definition(order: order, column: column, row: row, columns: columns, rows: rows) do
    %{
      order: order,
      name: "Battery",
      type: "batteryOverview",
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      metrics: [
        %{module: OVCS1, key: :pack_voltage},
        %{module: OVCS1, key: :pack_state_of_charge},
        %{module: OVCS1, key: :pack_average_temperature},
        %{module: OVCS1, key: :pack_current},
        %{module: OVCS1, key: :pack_is_charging},
        %{module: OVCS1, key: :j1772_plug_state}
      ]
    }
  end
end
