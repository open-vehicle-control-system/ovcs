defmodule Obd2.Vms.Composer.Dashboard.DiscoveryPage do
  alias Obd2.Vms.{Diagnostics, Discovery}

  def definition(order: order) do
    %{
      name: "Discovery",
      icon: "MagnifyingGlassIcon",
      order: order,
      blocks: %{
        "supported-pids" => %{
          order: 0,
          name: "Supported Mode 01 PIDs",
          type: "table",
          full_width: true,
          rows: [
            %{type: :metric, name: "Count", module: Diagnostics, key: :supported_pid_count},
            %{type: :metric, name: "PIDs (raw list)", module: Diagnostics, key: :supported_pids}
          ]
        },
        "uds-did-scan" => %{
          order: 1,
          name: "UDS DID scan (Mode 22)",
          type: "table",
          full_width: true,
          rows: [
            %{type: :action, name: "Scan ECU identification DIDs (0xF180–0xF19E)", input_type: :button, input_name: "Scan", module: Discovery, action: "scan_dids"},
            %{type: :metric, name: "Status", module: Discovery, key: :discovery_status},
            %{type: :metric, name: "Responding DIDs", module: Discovery, key: :uds_did_count},
            %{type: :metric, name: "Decoded DIDs", module: Discovery, key: :uds_dids}
          ]
        },
        "bus-traffic" => %{
          order: 2,
          name: "Passive bus traffic",
          type: "table",
          full_width: true,
          rows: [
            %{type: :metric, name: "Unique frame IDs seen", module: Discovery, key: :bus_unique_ids},
            %{type: :metric, name: "Per-ID summary", module: Discovery, key: :bus_traffic}
          ]
        }
      }
    }
  end
end
