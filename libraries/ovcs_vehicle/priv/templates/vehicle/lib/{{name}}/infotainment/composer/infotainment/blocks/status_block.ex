defmodule <%= @module %>.Infotainment.Composer.Infotainment.Blocks.StatusBlock do
  @moduledoc """
  Example block — renders the current VMS status as a labelled cell.

  A block's `definition/1` is a map describing how the UI should
  render it. `type:` picks the widget (here `"status_grid"`); `source:`
  points at the module whose `status/0` the UI polls every
  `refresh_interval` ms.
  """
  alias <%= @module %>.Infotainment

  def definition(order: order, column: column, row: row, columns: columns, rows: rows) do
    %{
      order: order,
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      type: "status_grid",
      source: Infotainment,
      cells: [
        %{label: "VMS", key: :vms_status}
      ]
    }
  end
end
