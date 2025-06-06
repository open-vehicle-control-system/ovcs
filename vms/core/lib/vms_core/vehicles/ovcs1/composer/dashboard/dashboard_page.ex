defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.DashboardPage do
  alias VmsCore.Components.{
    Bosch,
    Nissan.LeafAZE0,
    Volkswagen.Polo9N,
    OVCS
  }
  alias VmsCore.{Managers, Status}
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
          rows: [
            %{type: :metric, name: "Control Level", module: Managers.ControlLevel, key: :selected_control_level},
            %{type: :metric, name: "Manual Control forced", module: Managers.ControlLevel, key: :forced_to_manual},
            %{type: :metric, name: "Selected Gear", module: Managers.Gear, key: :selected_gear},
            %{type: :metric, name: "Key Status", module: Polo9N.IgnitionLock, key: :contact},
            %{type: :metric, name: "Speed", module: Polo9N.ABS, key: :speed, unit: "kph"},
            %{type: :metric, name: "RPM", module: LeafAZE0.Inverter, key: :rotation_per_minute},
            %{type: :metric, name: "Output Voltage", module: LeafAZE0.Inverter, key: :inverter_output_voltage, unit: "V"},
            %{type: :metric, name: "Motor temperature", module: LeafAZE0.Inverter, key: :motor_temperature, unit: "°C"}
          ]
        },
        "throttle" => Blocks.ThrottleChart.definition(order: 1, full_width: false),
        "torque" => Blocks.TorqueChart.definition(order: 2, full_width: false),
        "status" => %{
          order: 3,
          name: "Ready to drive",
          type: "table",
          rows: [
            %{type: :action, name: "Reset Status", input_type: :button, module: Status, action: "reset_status"},
            %{type: :metric, name: "VMS Status", module: OVCS1, key: :vms_status},
            %{type: :metric, name: "OVCS1 ready", module: OVCS1, key: :ready_to_drive},
            %{type: :metric, name: "Front Controller alive", module: OVCS1.FrontController, key: :is_alive},
            %{type: :metric, name: "Controls Controller alive", module: OVCS1.ControlsController, key: :is_alive},
            %{type: :metric, name: "Rear Controller alive", module: OVCS1.RearController, key: :is_alive},
            %{type: :metric, name: "Inverter ready", module: LeafAZE0.Inverter, key: :ready_to_drive},
            %{type: :metric, name: "I Booster ready", module: Bosch.IBoosterGen2, key: :ready_to_drive},
            %{type: :metric, name: "Contactors ready", module: OVCS.HighVoltageContactors, key: :ready_to_drive},
            %{type: :metric, name: "Main Negative contactor enabled", module: OVCS1.RearController, key: :received_digital_pin3_enabled},
            %{type: :metric, name: "Main Positive contactor enabled", module: OVCS1.RearController, key: :received_digital_pin4_enabled},
            %{type: :metric, name: "Precharge contactor enabled", module: OVCS1.RearController, key: :received_digital_pin5_enabled}
          ]
        },
        "rpm-voltage" => %{
          order: 5,
          name: "RPM & Voltage",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: 0, max: 10000, label: "RPM", series: [
              %{name: "RPM", metric: %{module: LeafAZE0.Inverter, key: :rotation_per_minute}}
            ]},
            %{position: "right", min: 0, max: 400, label: "V", series: [
              %{name: "Voltage", metric: %{module: LeafAZE0.Inverter, key: :inverter_output_voltage}}
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
