defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard do
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard

  def dashboard_configuration do
    %{
      vehicle: %{
        name: "OVCS1",
        main_color: "indigo", # One of orange|red|blue|indigo|gray|green|amber|rose|teal
        refresh_interval: 70,
        pages: %{
          "dashboard"           => Dashboard.DashboardPage.definition(order: 0),
          "steering-column"     => Dashboard.SteeringColumnPage.definition(order: 1),
          "throttle-pedal"      => Dashboard.ThrottlePedalPage.definition(order: 2),
          "brake-booster"       => Dashboard.BrakeBoosterPage.definition(order: 3),
          "inverter"            => Dashboard.InverterPage.definition(order: 4),
          "radio-control"       => Dashboard.RadioControlPage.definition(order: 5),
          "generic-controllers" => Dashboard.GenericControllersPage.definition(order: 6),
        }
      }
    }
  end
end
