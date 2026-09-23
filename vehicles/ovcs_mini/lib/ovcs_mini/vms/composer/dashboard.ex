defmodule OvcsMini.Vms.Composer.Dashboard do
  alias OvcsMini.Vms.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "OVCS Mini",
        # One of orange|red|blue|indigo|gray|green|amber|rose|teal
        main_color: "orange",
        refresh_interval: 70,
        # Each page shows what its own components produce, one block per
        # component. The main dashboard is the exception: it summarises
        # across components what is worth seeing at a glance.
        pages: %{
          "dashboard" => Dashboard.DashboardPage.definition(order: 0),
          "drivetrain" => Dashboard.DrivetrainPage.definition(order: 1),
          "radio-control" => Dashboard.RadioControlPage.definition(order: 2),
          "ros-control" => Dashboard.ROSControlPage.definition(order: 3),
          "generic-controllers" => Dashboard.GenericControllersPage.definition(order: 4)
        }
      }
    }
  end
end
