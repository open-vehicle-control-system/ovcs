defmodule Ovcs1.Infotainment.Composer.Infotainment.Blocks.BatteryOverviewBlock do
  alias Ovcs1.Infotainment

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
        %{module: Infotainment, key: :pack_voltage},
        %{module: Infotainment, key: :pack_state_of_charge},
        %{module: Infotainment, key: :pack_average_temperature},
        %{module: Infotainment, key: :pack_current},
        %{module: Infotainment, key: :pack_is_charging},
        %{module: Infotainment, key: :j1772_plug_state}
      ]
    }
  end
end
