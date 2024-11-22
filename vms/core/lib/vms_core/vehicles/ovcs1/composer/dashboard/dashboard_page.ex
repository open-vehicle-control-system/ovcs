defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.DashboardPage do
  alias VmsCore.Components.{
    Bosch,
    Nissan.LeafZE0,
    Volkswagen.Polo9N,
    OVCS
  }
  alias VmsCore.{Managers}
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard.Blocks
  alias VmsCore.Vehicles.OVCS1

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
          metrics: [
            %{name: "Control Level", module: Managers.ControlLevel, key: :selected_control_level},
            %{name: "Manual Control forced", module: Managers.ControlLevel, key: :forced_to_manual},
            %{name: "Selected Gear", module: Managers.Gear, key: :selected_gear},
            %{name: "Key Status", module: Polo9N.IgnitionLock, key: :contact},
            %{name: "Speed", module: Polo9N.ABS, key: :speed, unit: "kph"},
            %{name: "RPM", module: LeafZE0.Inverter, key: :rotation_per_minute},
            %{name: "Output Voltage", module: LeafZE0.Inverter, key: :inverter_output_voltage, unit: "V"},
            %{name: "Motor temperature", module: LeafZE0.Inverter, key: :motor_temperature, unit: "°C"}
          ]
        },
        "throttle" => Blocks.ThrottleChart.definition(order: 1, full_width: false),
        "torque" => Blocks.TorqueChart.definition(order: 2, full_width: false),
        "Modules Status" => %{
          order: 3,
          name: "Ready to drive",
          type: "table",
          metrics: [
            %{name: "VMS Status", module: OVCS1, key: :vms_status},
            %{name: "OVCS1 ready", module: OVCS1, key: :ready_to_drive},
            %{name: "Inverter ready", module: LeafZE0.Inverter, key: :ready_to_drive},
            %{name: "I Booster ready", module: Bosch.IBoosterGen2, key: :ready_to_drive},
            %{name: "Contactors ready", module: OVCS.HighVoltageContactors, key: :ready_to_drive},
            %{name: "Main Negative contactor enabled", module: OVCS.HighVoltageContactors, key: :main_negative_relay_enabled},
            %{name: "Main Positive contactor enabledy", module: OVCS.HighVoltageContactors, key: :main_positive_relay_enabled},
            %{name: "Precharge contactor enabled", module: OVCS.HighVoltageContactors, key: :precharge_relay_enabled},
          ]
        },
        "rpm-voltage" => %{
          order: 5,
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
          order: 6,
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
