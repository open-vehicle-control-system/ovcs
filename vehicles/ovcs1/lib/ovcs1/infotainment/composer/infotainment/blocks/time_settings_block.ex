defmodule Ovcs1.Infotainment.Composer.Infotainment.Blocks.TimeSettingsBlock do
  alias InfotainmentCore.TimeSettings

  def definition(order: order, column: column, row: row, columns: columns, rows: rows) do
    %{
      order: order,
      name: "Time Settings",
      type: "timeSettings",
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      metrics: [
        %{module: TimeSettings, key: :timezone},
        %{module: TimeSettings, key: :time_format},
        %{module: TimeSettings, key: :date_format}
      ],
      actions: [
        %{module: TimeSettings, action: "set_timezone"},
        %{module: TimeSettings, action: "set_time_format"},
        %{module: TimeSettings, action: "set_date_format"}
      ]
    }
  end
end
