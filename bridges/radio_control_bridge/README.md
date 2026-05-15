# radio_control_bridge

Elixir bridge library that lets an OVCS vehicle accept commands from a
MAVLink-compatible RC transmitter (ExpressLRS handsets, OpenTX radios,
…). Implements the [`OvcsBridge`](../../libraries/ovcs_bridge) behaviour;
hosted by [`bridges/firmware`](../firmware) and opted into per vehicle
through `bridge_firmwares/0`.

## What it does

- **MAVLink RC in** — reads MAVLink v2 `RC_CHANNELS` (and friends) from
  a UART connected to the RC receiver via [`express_lrs`](../../libraries/express_lrs),
  translates channels into throttle / steering / direction / control-mode
  CAN frames on the OVCS bus.
- **MSP OSD out** — pushes vehicle telemetry (RSSI, gear, speed, …) back
  to MSP-compatible VTXs (HDZero / Walksnail / DJI) via
  [`msp_osd`](../../libraries/msp_osd), so the pilot sees OVCS state on
  the goggles' OSD.

## Children

```
RadioControlBridge.children/0:
  - ExpressLrs.Connector  (UART → MAVLink decoder)
  - MavlinkForwarder      (decoded frames → OvcsBus / CAN)
  - MspOsdForwarder       (vehicle metrics → MSP DisplayPort)
```

## Vehicle-side configuration

Vehicles declare RC config via the `RadioControlBridge` behaviour on
their top-level module:

```elixir
@behaviour RadioControlBridge

@impl RadioControlBridge
def radio_control_bridge_config(:host),
  do: %RadioControlBridge.Config{uart_port: "ttyUSB0", uart_baud_rate: 460_800}

def radio_control_bridge_config(:target),
  do: %RadioControlBridge.Config{uart_port: "ttySC0", uart_baud_rate: 460_800}
```

## Dependencies

- `ovcs_bridge` — supervision contract.
- `express_lrs` — MAVLink v2 receive path.
- `msp_osd` — MSP / DisplayPort transmit path.

The bridge is bundled into a firmware image via the vehicle's
`bridge_firmwares/0` map — see
[`docs/vehicle_parameterisation.md`](../../docs/vehicle_parameterisation.md#bridge-firmwares).
