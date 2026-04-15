defmodule Obd2.Infotainment.Composer.Infotainment.Blocks.SpeedGaugeBlock do
  alias Obd2.Infotainment

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
        %{module: Infotainment, key: :speed}
      ],
      config: %{
        unit: "km/h",
        min: 0,
        max: 180
      }
    }
  end
end
