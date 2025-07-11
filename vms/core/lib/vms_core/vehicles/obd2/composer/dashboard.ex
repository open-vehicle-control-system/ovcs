defmodule VmsCore.Vehicles.OBD2.Composer.Dashboard do
  alias VmsCore.Vehicles.OBD2.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "OVCS OBD2",
        main_color: "green", # One of orange|red|blue|indigo|gray|green|amber|rose|teal
        refresh_interval: 70,
        pages: %{
          "dashboard"       => Dashboard.DashboardPage.definition(order: 0)
        }
      }
    }
  end
end
