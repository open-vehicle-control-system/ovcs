defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard do
  alias VmsCore.Vehicles.OVCSMini.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "OVCS Mini",
        main_color: "orange", # One of orange|red|blue|indigo|gray|green|amber|rose|teal
        refresh_interval: 70,
        pages: %{
          "dashboard"       => Dashboard.DashboardPage.definition(order: 0),
          "radio-control"   => Dashboard.RadioControlPage.definition(order: 1),
        }
      }
    }
  end
end
