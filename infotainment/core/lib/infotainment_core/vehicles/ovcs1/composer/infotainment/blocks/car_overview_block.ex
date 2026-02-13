defmodule InfotainmentCore.Vehicles.OVCS1.Composer.Infotainment.Blocks.CarOverviewBlock do
  alias InfotainmentCore.Vehicles.OVCS1

  def definition(order: order, columns: columns, rows: rows) do
    %{
      order: order,
      name: "Car Overview",
      type: "carOverview",
      columns: columns,
      rows: rows,
      metrics: [
        %{module: OVCS1, key: :front_left_door_open},
        %{module: OVCS1, key: :front_right_door_open},
        %{module: OVCS1, key: :rear_left_door_open},
        %{module: OVCS1, key: :rear_right_door_open},
        %{module: OVCS1, key: :trunk_door_open},
        %{module: OVCS1, key: :beam_active},
        %{module: OVCS1, key: :handbrake_engaged},
        %{module: OVCS1, key: :ready_to_drive},
      ]
    }
  end
end
