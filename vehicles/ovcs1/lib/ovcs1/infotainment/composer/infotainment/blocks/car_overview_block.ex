defmodule Ovcs1.Infotainment.Composer.Infotainment.Blocks.CarOverviewBlock do
  alias Ovcs1.Infotainment

  def definition(order: order, column: column, row: row, columns: columns, rows: rows) do
    %{
      order: order,
      name: "Car Overview",
      type: "carOverview",
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      metrics: [
        %{module: Infotainment, key: :front_left_door_open},
        %{module: Infotainment, key: :front_right_door_open},
        %{module: Infotainment, key: :rear_left_door_open},
        %{module: Infotainment, key: :rear_right_door_open},
        %{module: Infotainment, key: :trunk_door_open},
        %{module: Infotainment, key: :beam_active},
        %{module: Infotainment, key: :handbrake_engaged},
        %{module: Infotainment, key: :ready_to_drive}
      ]
    }
  end
end
