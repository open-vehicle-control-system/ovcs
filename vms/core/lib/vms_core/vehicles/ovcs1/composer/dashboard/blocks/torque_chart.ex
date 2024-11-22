defmodule VmsCore.Vehicles.OVCS1.Composer.Dashboard.Blocks.TorqueChart do
  alias VmsCore.Components.Nissan.LeafZE0.Inverter

  def definition(order: order, full_width: full_width) do
    %{
      order: order,
      name: "Torque",
      type: "lineChart",
      full_width: full_width,
      serie_max_size: 300,
      y_axis: [
        %{min: Inverter.reverse_max_torque(), max: Inverter.drive_max_torque(), label: "Nm", series: [
          %{name: "Effective Torque", metric: %{module: Inverter, key: :effective_torque}},
          %{name: "Requested Torque", metric: %{module: Inverter, key: :requested_torque}}
        ]}
      ]
    }
  end
end
