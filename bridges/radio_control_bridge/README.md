# radio_control_bridge

Elixir bridge library that lets an OVCS vehicle accept commands from a
MAVLink-compatible RC transmitter (ExpressLRS handsets, OpenTX radios,
…). Implements the [`OvcsBridge`](../../libraries/ovcs_bridge) behaviour;
hosted by [`bridges/firmware`](../firmware) and opted into per vehicle
through `bridge_firmwares/0`.

The guide, [Radio control bridge](../../docs/bridges/radio_control.md), explains what it
does, its components and how a vehicle configures it; this README keeps the developer
details.

## Adding a component

Each entry of `%RadioControlBridge.Config{components: ...}` resolves to child specs
through `RadioControlBridge.Components.start/2`. A new component is one more clause in
`lib/radio_control_bridge/components.ex`.

## Dependencies

- `ovcs_bridge` — supervision contract.
- `express_lrs` — MAVLink v2 receive path.
- `msp_osd` — MSP / DisplayPort transmit path.

The bridge is bundled into a firmware image via the vehicle's
`bridge_firmwares/0` map — see
[Bridge firmwares](../../docs/bridges/README.md#bridge-firmwares).
