defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard do
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "OVCS1",
        main_color: "indigo", # One of orange|red|blue|indigo|gray|green|amber|rose|teal
        refresh_interval: 70,
        pages: %{
          "dashboard"       => Dashboard.DashboardPage.definition(),
          "steering-column" => Dashboard.SteeringColumnPage.definition(),
          "throttle-pedal"  => Dashboard.ThrottlePedalPage.definition(),
          "inverter"        => Dashboard.InverterPage.definition(),
          "radio-control"   => Dashboard.RadioControlPage.definition(),
        }
      }
    }
  end
end
