defmodule Ovcs1.Infotainment.Composer.Infotainment.DashboardPage do
  alias Ovcs1.Infotainment.Composer.Infotainment.Blocks

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "dashboard",
      order: order,
      # background_image: "assets/images/other_background.png", # per-page override (optional)
      blocks: %{
        "gear-selector" =>
          Blocks.GearSelectorBlock.definition(order: 0, column: 0, row: 0, columns: 4, rows: 5),
        "speed-gauge" =>
          Blocks.SpeedGaugeBlock.definition(order: 1, column: 4, row: 0, columns: 10, rows: 5),
        "car-overview" =>
          Blocks.CarOverviewBlock.definition(order: 2, column: 14, row: 0, columns: 10, rows: 5),
        "battery-overview" =>
          Blocks.BatteryOverviewBlock.definition(
            order: 3,
            column: 0,
            row: 5,
            columns: 12,
            rows: 3
          ),
        "status-grid" =>
          Blocks.StatusGridBlock.definition(order: 4, column: 12, row: 5, columns: 12, rows: 3)
      }
    }
  end
end
