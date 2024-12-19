defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard.DashboardPage do
  alias VmsCore.Vehicles.OVCSMini.Composer.Dashboard.Blocks
  alias VmsCore.Vehicles.OVCSMini
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
            %{type: :metric, name: "VMS Status", module: OVCSMini, key: :vms_status},
            %{type: :metric, name: "OVCSMini ready", module: OVCSMini, key: :ready_to_drive},
            %{type: :metric, name: "Main Controller Alive", module: OVCSMini.MainController, key: :is_alive},
          ]
        },
        "throttle" => Blocks.RadioControlThrottleAndSteeringBlock.definition(order: 1, full_width: false)
      }
    }
  end
end
