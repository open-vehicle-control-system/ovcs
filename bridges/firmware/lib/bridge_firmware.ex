defmodule BridgeFirmware do
  @moduledoc """
  Shared Nerves firmware image that can bundle one or more bridge
  libraries. Parameterised at build time by:

    * `VEHICLE`            — vehicle package top-level module
    * `BRIDGE_FIRMWARE_ID` — key into the vehicle's `bridge_firmwares/0`

  The `BridgeFirmware.Application` root supervisor reads both from
  env at boot, looks up the matching entry in the vehicle's map, and
  starts each bundled bridge's `children/0` as a flat list.
  """
end
