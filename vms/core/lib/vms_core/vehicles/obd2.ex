defmodule VmsCore.Vehicles.OBD2 do
  @moduledoc """
  OBD2 diagnostic vehicle.

  Turns the VMS into an OBD2 / KWP2000 / UDS scan tool: live PIDs,
  stored / pending / permanent / UDS DTCs, vehicle information,
  passive bus sniffing and UDS DID probing.

  The actual work happens in:

    * `VmsCore.Vehicles.OBD2.Diagnostics` — standard request loops
      (live data, DTCs, vehicle info) and on-demand actions like
      Mode 04 / Mode 14 clear-DTC and UDS extended session control.

    * `VmsCore.Vehicles.OBD2.Discovery` — passive frame sniffing on
      the OBD2 bus and active UDS Mode 22 DID walks for ECU
      fingerprinting.

  Both publish their results on the VMS Bus so the dashboard's metrics
  channel picks them up automatically.
  """
end
