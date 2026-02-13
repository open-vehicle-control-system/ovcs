defmodule InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment.Blocks.GearSelectorBlock do
  alias InfotainmentCore.Vehicles.OVCS1

  def definition(order: order, columns: columns, rows: rows) do
    %{
      order: order,
      name: "Gear Selector",
      type: "gearSelector",
      columns: columns,
      rows: rows,
      metrics: [
        %{module: OVCS1, key: :selected_gear}
      ],
      actions: [
        %{module: OVCS1, action: "request_gear"}
      ]
    }
  end
end
