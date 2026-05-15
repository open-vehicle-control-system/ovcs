defmodule Ovcs1.Infotainment.Composer.Infotainment.Blocks.GearSelectorBlock do
  alias Ovcs1.Infotainment

  def definition(order: order, column: column, row: row, columns: columns, rows: rows) do
    %{
      order: order,
      name: "Gear Selector",
      type: "gearSelector",
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      metrics: [
        %{module: Infotainment, key: :selected_gear}
      ],
      actions: [
        %{module: Infotainment, action: "request_gear"}
      ]
    }
  end
end
