defmodule <%= @module %>.Infotainment.Composer.Infotainment.Blocks.StatusBlock do
  @moduledoc """
  Example block: renders the current VMS status in a status grid.

  A block's `definition/1` is a map describing how the head unit renders
  it. `type:` picks the widget (`"statusGrid"`); each entry in `metrics:`
  names the module whose `status/0` supplies the value under `key:`.
  """
  alias <%= @module %>.Infotainment

  def definition(order: order, column: column, row: row, columns: columns, rows: rows) do
    %{
      order: order,
      column: column,
      row: row,
      columns: columns,
      rows: rows,
      name: "Status",
      type: "statusGrid",
      metrics: [
        %{module: Infotainment, key: :vms_status, label: "VMS"}
      ]
    }
  end
end
