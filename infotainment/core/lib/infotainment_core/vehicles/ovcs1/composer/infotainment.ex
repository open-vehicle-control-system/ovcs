defmodule InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment do
  alias InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment

  def infotainment_configuration do
    %{
      vehicle: %{
        name: "OVCS1",
        main_color: "indigo",
        refresh_interval: 50,
        grid_columns: 12,
        grid_rows: 4,
        background_image: "assets/images/launchpad_background.png",
        block_style: %{
          background_color: "D9111827",
          border_radius: 30,
          padding: 20,
          margin: 10
        },
        pages: %{
          "dashboard" => Infotainment.DashboardPage.definition(order: 0),
          "settings" => Infotainment.SettingsPage.definition(order: 1)
        }
      }
    }
  end
end
