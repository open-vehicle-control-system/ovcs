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

## Components — per-vehicle configuration

`RadioControlBridge.children/0` isn't hardcoded — every feature is a
component the vehicle opts into via the `:components` field of its
`%RadioControlBridge.Config{}`. The bridge resolves each entry into
one or more child specs via `RadioControlBridge.Components.start/2`.

Catalogue (extend by adding a clause to
`lib/radio_control_bridge/components.ex`):

| Component             | Opts                                                                                 | Child specs started |
|-----------------------|--------------------------------------------------------------------------------------|---------------------|
| `:mavlink_forwarder`  | `:uart_port`, `:uart_baud_rate` (both required) — the ExpressLRS receiver UART. Read by `bridges/firmware`'s `runtime.exs` to stamp `:express_lrs` Application env before `ExpressLrs.Application` boots. | `RadioControlBridge.MavlinkForwarder` (decoded MAVLink → CAN) |
| `:msp_osd_forwarder`  | (none yet; will gain its own `:uart_port` / `:uart_baud_rate` when implemented — separate serial line to the VTX, not the ExpressLRS receiver) | `RadioControlBridge.MspOsdForwarder` (placeholder) |

UART pins live with the component that uses them — two forwarders
that drive separate hardware (ExpressLRS receiver vs. MSP
DisplayPort to a VTX) don't share a single global UART field.
`ExpressLrs.Mavlink.Connector` itself is started from
`bridges/firmware`'s application tree once `runtime.exs` has read
the component opts; it's not a child of this bridge.

## Vehicle-side configuration

Vehicles declare RC config via the `RadioControlBridge` behaviour on
their top-level module. The `:host` arm typically lists no
components (no UART hardware); the `:target` arm enables
`:mavlink_forwarder` with the Pi UART pin baked into its opts.

```elixir
@behaviour RadioControlBridge

@impl RadioControlBridge
def radio_control_bridge_config(:host),
  do: %RadioControlBridge.Config{components: []}

def radio_control_bridge_config(:target),
  do: %RadioControlBridge.Config{
    components: [
      {:mavlink_forwarder, uart_port: "ttySC0", uart_baud_rate: 460_800}
    ]
  }
```

A bare atom is shorthand for `{atom, []}`. An unknown component
name raises `FunctionClauseError` at supervisor boot — typos in the
list fail loudly rather than silently dropping a feature.

## Dependencies

- `ovcs_bridge` — supervision contract.
- `express_lrs` — MAVLink v2 receive path.
- `msp_osd` — MSP / DisplayPort transmit path.

The bridge is bundled into a firmware image via the vehicle's
`bridge_firmwares/0` map — see
[`docs/vehicle_parameterisation.md`](../../docs/vehicle_parameterisation.md#bridge-firmwares).
