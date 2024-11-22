defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard do
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "OVCS1",
        main_color: "#CCCCCC",
        refresh_interval: 70,
        pages: %{
          "dashboard"       => Dashboard.DashboardPage.definition(),
          "steering-column" => Dashboard.SteeringColumnPage.definition(),
          "throttle"        => Dashboard.ThrottlePage.definition()
        }
      }
    }
  end
end
