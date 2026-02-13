defmodule InfotainmentCore.Vehicles.OBD2.Composer.Infotainment.DashboardPage do
  alias InfotainmentCore.Vehicles.OBD2
  alias InfotainmentCore.Vehicles.OBD2.Composer.Infotainment.Blocks

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "dashboard",
      order: order,
      blocks: %{
        "speed-gauge" =>
          Blocks.SpeedGaugeBlock.definition(order: 0, column: 0, row: 0, columns: 6, rows: 4)
      }
    }
  end
end
