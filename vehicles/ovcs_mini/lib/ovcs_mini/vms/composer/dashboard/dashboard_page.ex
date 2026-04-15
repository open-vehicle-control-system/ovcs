defmodule OvcsMini.Vms.Composer.Dashboard.DashboardPage do
  alias OvcsMini.Vms
  alias VmsCore.{Status}

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "HomeIcon",
      order: order,
      blocks: %{
        "status" => %{
          order: 0,
          name: "Ready to drive",
          type: "table",
          rows: [
            %{type: :action, name: "Reset Status", input_type: :button, module: Status, action: "reset_status"},
            %{type: :metric, name: "VMS Status", module: Vms, key: :vms_status},
            %{type: :metric, name: "OVCSMini ready", module: Vms, key: :ready_to_drive},
            %{type: :metric, name: "Main Controller Alive", module: Vms.MainController, key: :is_alive},
          ]
        }
      }
    }
  end
end
