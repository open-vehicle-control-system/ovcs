defmodule VmsCore.Vehicles.OVCSMini.Composer.Dashboard.DashboardPage do
  alias VmsCore.Vehicles.OVCSMini.Composer.Dashboard.Blocks
  alias VmsCore.Vehicles.OVCSMini

  def definition(order: order) do
    %{
      name: "Dashboard",
      icon: "HomeIcon",
      order: order,
      blocks: %{
        "Modules Status" => %{
          order: 0,
          name: "Ready to drive",
          type: "table",
          metrics: [
            %{name: "VMS Status", module: OVCSMini, key: :vms_status},
            %{name: "OVCSMini ready", module: OVCSMini, key: :ready_to_drive},
          ]
        },
        "throttle" => Blocks.RadioControlThrottleAndSteeringBlock.definition(order: 1, full_width: false)
      }
    }
  end
end
