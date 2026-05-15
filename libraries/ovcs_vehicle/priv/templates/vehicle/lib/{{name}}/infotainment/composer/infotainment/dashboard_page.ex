defmodule <%= @module %>.Infotainment.Composer.Infotainment.DashboardPage do
  @moduledoc "Dashboard page: a single status block as a starting point."
  alias <%= @module %>.Infotainment.Composer.Infotainment.Blocks

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "dashboard",
      order: order,
      blocks: %{
        "vms-status" =>
          Blocks.StatusBlock.definition(order: 0, column: 0, row: 0, columns: 24, rows: 8)
      }
    }
  end
end
