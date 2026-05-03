defmodule VmsCore.Vehicles.OBD2.Composer.Dashboard.DtcsPage do
  alias VmsCore.Vehicles.OBD2.Diagnostics

  def definition(order: order) do
    %{
      name: "DTCs",
      icon: "ExclamationTriangleIcon",
      order: order,
      blocks: %{
        "obd2-dtcs" => %{
          order: 0,
          name: "OBD2 emission codes (Mode 03 / 07 / 0A)",
          type: "table",
          full_width: true,
          rows: [
            %{type: :action, name: "Clear emission DTCs", input_type: :button, input_name: "Send Mode 04", module: Diagnostics, action: "clear_dtcs"},
            %{type: :metric, name: "Stored DTCs", module: Diagnostics, key: :stored_dtcs},
            %{type: :metric, name: "Stored count", module: Diagnostics, key: :stored_dtc_count},
            %{type: :metric, name: "Pending DTCs", module: Diagnostics, key: :pending_dtcs},
            %{type: :metric, name: "Pending count", module: Diagnostics, key: :pending_dtc_count},
            %{type: :metric, name: "Permanent DTCs", module: Diagnostics, key: :permanent_dtcs},
            %{type: :metric, name: "Permanent count", module: Diagnostics, key: :permanent_dtc_count}
          ]
        },
        "uds-dtcs" => %{
          order: 1,
          name: "UDS DTCs (Mode 19 / 14)",
          type: "table",
          full_width: true,
          rows: [
            %{type: :action, name: "Clear UDS DTCs", input_type: :button, input_name: "Send Mode 14", module: Diagnostics, action: "uds_clear_dtcs"},
            %{type: :metric, name: "UDS DTCs", module: Diagnostics, key: :uds_dtcs},
            %{type: :metric, name: "UDS count", module: Diagnostics, key: :uds_dtc_count}
          ]
        }
      }
    }
  end
end
