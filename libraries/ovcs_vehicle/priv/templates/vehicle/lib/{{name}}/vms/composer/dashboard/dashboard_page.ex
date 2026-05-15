defmodule <%= @module %>.Vms.Composer.Dashboard.DashboardPage do
  @moduledoc """
  A dashboard page is a map of named "blocks". Each block has a
  `type` (`"table"`, `"lineChart"`, `"gauge"`, …) and reads metrics
  from a Bus-publishing module via `module:` + `key:`.

  Add more blocks (one per feature) or replace this page with several
  feature-specific pages — see `Dashboard.dashboard_configuration/0`.
  """
  alias <%= @module %>.Vms

  def definition(order: order) do
    %{
      name: "Status",
      icon: "HomeIcon",
      order: order,
      blocks: %{
        "vms-status" => %{
          order: 0,
          name: "VMS",
          type: "table",
          rows: [
            %{type: :metric, name: "Status", module: Vms, key: :vms_status},
            %{type: :metric, name: "Ready to drive", module: Vms, key: :ready_to_drive}
          ]
        }
      }
    }
  end
end
