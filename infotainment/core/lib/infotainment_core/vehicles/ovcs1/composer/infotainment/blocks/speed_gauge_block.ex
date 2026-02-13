defmodule InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment.Blocks.SpeedGaugeBlock do
  alias InfotainmentCore.Vehicles.OVCS1

  def definition(order: order, column: column, row: row, columns: columns, rows: rows) do
    %{
      order: order,
      name: "Speed",
      type: "speedGauge",
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      metrics: [
        %{module: OVCS1, key: :speed}
      ],
      config: %{
        unit: "km/h",
        min: 0,
        max: 180
      }
    }
  end
end
