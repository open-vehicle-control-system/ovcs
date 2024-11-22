defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.DashboardPage do
  alias VmsCore.Components.{
    Nissan.LeafZE0,
    Volkswagen.Polo9N
  }
  alias VmsCore.{Managers}
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard.Blocks

  def definition do
    %{
      name: "Dashboard",
      icon: "HomeIcon",
      blocks: %{
        "vehicle-information" => %{
          order: 0,
          name: "Vehicle Information",
          type: "table",
          metrics: [
            %{name: "Selected Gear", module: Managers.Gear, key: :selected_gear},
            %{name: "Key Status", module: Polo9N.IgnitionLock, key: :contact},
            %{name: "Speed", module: Polo9N.ABS, key: :speed, unit: "kph"},
            %{name: "RPM", module: LeafZE0.Inverter, key: :rotation_per_minute},
            %{name: "Output Voltage", module: LeafZE0.Inverter, key: :inverter_output_voltage, unit: "V"},
            %{name: "Motor temperature", module: LeafZE0.Inverter, key: :motor_temperature, unit: "°C"}
          ]
        },
        "throttle" => Blocks.ThrottleChart.definition(order: 1),
        "torque" => %{
          order: 2,
          name: "Torque",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: LeafZE0.Inverter.reverse_max_torque(), max: LeafZE0.Inverter.drive_max_torque(), label: "Nm", series: [
              %{name: "Effective Torque", metric: %{module: LeafZE0.Inverter, key: :effective_torque}},
              %{name: "Requested Torque", metric: %{module: LeafZE0.Inverter, key: :requested_torque}}
            ]}
          ]
        },
        "temperature" => %{
          order: 3,
          name: "Temperature",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: -50, max: 200, label: "°C", series: [
              %{name: "Inverter Board", metric: %{module: LeafZE0.Inverter, key: :inverter_communication_board_temperature}},
              %{name: "IGBT", metric: %{module: LeafZE0.Inverter, key: :insulated_gate_bipolar_transistor_temperature}},
              %{name: "IGBT Board", metric: %{module: LeafZE0.Inverter, key: :insulated_gate_bipolar_transistor_board_temperature}},
              %{name: "Motor", metric: %{module: LeafZE0.Inverter, key: :motor_temperature}},
            ]}
          ]
        },
        "rpm-voltage" => %{
          order: 4,
          name: "RPM & Voltage",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: 0, max: 10000, label: "RPM", series: [
              %{name: "RPM", metric: %{module: LeafZE0.Inverter, key: :rotation_per_minute}}
            ]},
            %{position: "right", min: 0, max: 400, label: "V", series: [
              %{name: "Voltage", metric: %{module: LeafZE0.Inverter, key: :inverter_output_voltage}}
            ]}
          ]
        },
        "speed" => %{
          order: 5,
          name: "Speed",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: 0, max: 200, label: "kph", series: [
              %{name: "Speed", metric: %{module: Polo9N.ABS, key: :speed}},
            ]}
          ]
        }
      }
    }
  end
end
