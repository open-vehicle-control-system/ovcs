# Infotainment API

Phoenix 1.7 JSON + WebSocket server for the in-car touchscreen. Same shape
as [`vms_api`](../../vms/api) — a thin routing layer in front of
[`infotainment_core`](../core) — but serves the Flutter dashboard
(`../dashboard`) on the RPi 5 head unit instead of the Vue debug UI.

The guide, [Infotainment](../../docs/infotainment/README.md), lists the endpoints and
places this app among the infotainment layers; this README keeps the developer details.

## Running locally

```sh
cd infotainment/api
VEHICLE=Ovcs1 mix phx.server
```

Lands at `http://localhost:4001` (port chosen so VMS API + infotainment API
can coexist on a dev host). For the full vehicle-package boot, prefer
`./ovcs run <vehicle>` from the repo root.

## Required env vars

| Variable | Required | Purpose |
|----------|:-:|---------|
| `VEHICLE` | yes | Top-level vehicle module (`Ovcs1`, `Obd2`, …). The vehicle's `infotainment/0` must return an `InfotainmentCore.Vehicle` composer — vehicles with no head unit (e.g. `OvcsMini`) don't boot this app |
| `CAN_NETWORK_MAPPINGS` | no | Override the vehicle's `default_can_mapping(:host)` |

## Dependencies

Direct path dep: [`infotainment_core`](../core). Cantastic / OvcsBus /
OvcsCan come in transitively through `infotainment_core`. The active
vehicle package under `vehicles/<name>/` isn't a Mix dep — it's
resolved at runtime from `VEHICLE` by
`infotainment/firmware/config/runtime.exs` (via
`OvcsVehicle.Firmware.resolve_side/4`) before
`InfotainmentCore.Application` starts.
