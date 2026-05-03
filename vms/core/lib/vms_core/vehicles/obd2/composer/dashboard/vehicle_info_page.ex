defmodule VmsCore.Vehicles.OBD2.Composer.Dashboard.VehicleInfoPage do
  alias VmsCore.Vehicles.OBD2.Diagnostics

  def definition(order: order) do
    %{
      name: "Vehicle info",
      icon: "InformationCircleIcon",
      order: order,
      blocks: %{
        "identity" => %{
          order: 0,
          name: "Identification (Mode 09)",
          type: "table",
          full_width: true,
          rows: [
            %{type: :metric, name: "VIN", module: Diagnostics, key: :vin},
            %{type: :metric, name: "ECU name", module: Diagnostics, key: :ecu_name},
            %{type: :metric, name: "Calibration ID(s)", module: Diagnostics, key: :calibration_id}
          ]
        },
        "session" => %{
          order: 1,
          name: "UDS extended session",
          type: "table",
          rows: [
            %{type: :action, name: "Open extended session", input_type: :button, input_name: "Open", module: Diagnostics, action: "open_extended_session"},
            %{type: :action, name: "Close extended session", input_type: :button, input_name: "Close", module: Diagnostics, action: "close_extended_session"},
            %{type: :metric, name: "Session open", module: Diagnostics, key: :extended_session_open},
            %{type: :metric, name: "ECU P2 max", module: Diagnostics, key: :p2_server_max_ms, unit: "ms"},
            %{type: :metric, name: "ECU P2★ max", module: Diagnostics, key: :p2_star_server_max_ms, unit: "ms"}
          ]
        }
      }
    }
  end
end
