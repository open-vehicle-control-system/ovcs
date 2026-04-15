defmodule Obd2.Infotainment.Composer.Infotainment.DashboardPage do
  alias Obd2.Infotainment
  alias Obd2.Infotainment.Composer.Infotainment.Blocks

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "dashboard",
      order: order,
      blocks: %{
        "speed-gauge" =>
          Blocks.SpeedGaugeBlock.definition(order: 0, column: 0, row: 0, columns: 12, rows: 8)
      }
    }
  end
end
