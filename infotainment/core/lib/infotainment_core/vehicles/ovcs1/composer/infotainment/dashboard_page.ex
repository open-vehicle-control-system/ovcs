defmodule InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment.DashboardPage do
  alias InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment.Blocks

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "dashboard",
      order: order,
      # background_image: "assets/images/other_background.png", # per-page override (optional)
      blocks: %{
        "gear-selector"    => Blocks.GearSelectorBlock.definition(order: 0, columns: 1, rows: 4),
        "speed-gauge"      => Blocks.SpeedGaugeBlock.definition(order: 1, columns: 5, rows: 2),
        "car-overview"     => Blocks.CarOverviewBlock.definition(order: 2, columns: 6, rows: 2),
        "battery-overview" => Blocks.BatteryOverviewBlock.definition(order: 3, columns: 5, rows: 2),
        "status-grid"      => Blocks.StatusGridBlock.definition(order: 4, columns: 6, rows: 2),
      }
    }
  end
end
