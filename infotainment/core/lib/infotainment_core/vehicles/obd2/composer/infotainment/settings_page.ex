defmodule InfotainmentCore.Vehicles.OBD2.Composer.Infotainment.SettingsPage do
  alias InfotainmentCore.Vehicles.OBD2.Composer.Infotainment.Blocks

  def definition(order: order) do
    %{
      name: "Settings",
      icon: "settings",
      order: order,
      blocks: %{
        "time-settings" =>
          Blocks.TimeSettingsBlock.definition(order: 0, column: 0, row: 0, columns: 12, rows: 4)
      }
    }
  end
end
