defmodule Obd2.Vms.Composer.Dashboard do
  alias Obd2.Vms.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "OBD2 Scanner",
        main_color: "green",
        refresh_interval: 70,
        pages: %{
          "dashboard"     => Dashboard.DashboardPage.definition(order: 0),
          "live-data"     => Dashboard.LiveDataPage.definition(order: 1),
          "dtcs"          => Dashboard.DtcsPage.definition(order: 2),
          "vehicle-info"  => Dashboard.VehicleInfoPage.definition(order: 3),
          "discovery"     => Dashboard.DiscoveryPage.definition(order: 4)
        }
      }
    }
  end
end
