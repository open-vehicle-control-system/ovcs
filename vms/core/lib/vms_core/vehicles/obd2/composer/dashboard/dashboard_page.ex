defmodule VmsCore.Vehicles.OBD2.Composer.Dashboard.DashboardPage do
  alias VmsCore.Vehicles.OBD2

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "HomeIcon",
      order: order,
      blocks: %{
        "vehicle-information" => %{
          order: 0,
          name: "Vehicle Information",
          type: "table",
          rows: [
            %{type: :metric, name: "Speed", module: OBD2, key: :speed, unit: "kph"},
            %{type: :metric, name: "RPM", module: OBD2, key: :rotation_per_minute},
          ]
        },
        "rpm" => %{
          order: 5,
          name: "RPM & Speed",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: 0, max: 8000, label: "RPM", series: [
              %{name: "RPM", metric: %{module: OBD2, key: :rotation_per_minute}}
            ]},
            %{position: "right", min: 0, max: 150, label: "kph", series: [
              %{name: "Speed", metric: %{module: OBD2, key: :speed}}
            ]}
          ]
        }
      }
    }
  end
end
