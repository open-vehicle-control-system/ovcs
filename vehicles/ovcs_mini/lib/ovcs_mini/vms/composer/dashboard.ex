defmodule OvcsMini.Vms.Composer.Dashboard do
  alias OvcsMini.Vms.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "OVCS Mini",
        main_color: "orange", # One of orange|red|blue|indigo|gray|green|amber|rose|teal
        refresh_interval: 70,
        pages: %{
          "dashboard"       => Dashboard.DashboardPage.definition(order: 0),
          "radio-control"   => Dashboard.RadioControlPage.definition(order: 1),
          "ros-control"   => Dashboard.ROSControlPage.definition(order: 2),
          "generic-controllers" => Dashboard.GenericControllersPage.definition(order: 3),
        }
      }
    }
  end
end
