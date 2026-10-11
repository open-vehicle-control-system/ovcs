defmodule Ovcs1.Vms.Composer.Dashboard.Blocks.TorqueChart do
  alias Ovcs1.Vms.Composer
  alias VmsCore.Components.Nissan.LeafAZE0.Inverter

  def definition(order: order, full_width: full_width) do
    %{
      order: order,
      name: "Torque",
      type: "lineChart",
      full_width: full_width,
      serie_max_size: 300,
      y_axis: [
        %{
          min: -Composer.inverter_reverse_max_torque_nm(),
          max: Composer.inverter_drive_max_torque_nm(),
          label: "Nm",
          series: [
            %{name: "Effective Torque", metric: %{module: Inverter, key: :effective_torque}},
            %{name: "Requested Torque", metric: %{module: Inverter, key: :requested_torque}}
          ]
        }
      ]
    }
  end
end
