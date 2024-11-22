defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.InverterPage do
  alias VmsCore.Components.Nissan.LeafZE0.Inverter
  alias VmsCore.Vehicles.OVCS1.Composer.Dashboard.Blocks

  def definition(order: order) do
    %{
      name: "Inverter",
      icon: "BoltIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Status",
          type: "table",
          metrics: [
            %{name: "Requested Throttle Source", module: Inverter, key: :requested_throttle_source},
            %{name: "Requested Throttle", module: Inverter, key: :requested_throttle, unit: "%"},
            %{name: "Requested Torque", module: Inverter, key: :requested_torque, unit: "N/m"},
            %{name: "Effective Torque", module: Inverter, key: :effective_torque, unit: "N/m"},
            %{name: "RPM", module: Inverter, key: :rotation_per_minute},
            %{name: "Output Voltage", module: Inverter, key: :inverter_output_voltage, unit: "V"},
            %{name: "Motor temperature", module: Inverter, key: :motor_temperature, unit: "°C"}
          ]
        },
        "temperature" => %{
          order: 1,
          name: "Temperature",
          type: "lineChart",
          serie_max_size: 300,
          y_axis: [
            %{min: -50, max: 200, label: "°C", series: [
              %{name: "Inverter Board", metric: %{module: Inverter, key: :inverter_communication_board_temperature}},
              %{name: "IGBT", metric: %{module: Inverter, key: :insulated_gate_bipolar_transistor_temperature}},
              %{name: "IGBT Board", metric: %{module: Inverter, key: :insulated_gate_bipolar_transistor_board_temperature}},
              %{name: "Motor", metric: %{module: Inverter, key: :motor_temperature}},
            ]}
          ]
        },
        "torque" => Blocks.TorqueChart.definition(order: 2, full_width: true),
      }
    }
  end
end
