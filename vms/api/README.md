# VMS API

Phoenix 1.7 JSON + WebSocket server that exposes the VMS Core to the debug
dashboard. Thin layer — all logic lives in [`vms_core`](../core); controllers
and channels just route HTTP/WebSocket traffic to it.

See [`docs/applications.md`](../../docs/applications.md) for the three-layer
(`core` ← `api` ← `firmware`) architecture this app sits in.

## Endpoints

### REST

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/vehicle` | Vehicle metadata (name, main color, refresh interval) |
| `GET` | `/api/vehicle/pages` | Dashboard page list |
| `GET` | `/api/vehicle/pages/:page_id/blocks` | Blocks rendered on a given page |
| `POST` | `/api/actions` | Dispatch a control action to a component |

Page/block layout comes from the active vehicle's composer
(`<Vehicle>.Vms.Composer.dashboard_configuration/0`).

### WebSocket

Phoenix socket mounted at `/sockets/dashboard`. Channels:

| Topic | Purpose |
|-------|---------|
| `metrics` | Streams `VmsCore.Metrics` updates for module/key pairs the client subscribes to |
| `network-interfaces` | Streams `VmsCore.NetworkInterfaces` state (TX/RX stats, bus state) |

### Dev-only

- `/dev/dashboard` — Phoenix LiveDashboard (Erlang VM introspection)

## Running locally

```sh
cd vms/api
VEHICLE=Ovcs1 mix phx.server      # or iex -S mix phx.server
```

Lands at `http://localhost:4000`. For the full vehicle-package boot (one
BEAM per firmware — VMS, infotainment, each bridge — joined into a single
Erlang-distribution cluster), prefer `./ovcs run <vehicle>` from the repo
root — see [`docs/getting_started.md`](../../docs/getting_started.md).

## Required env vars

| Variable | Required | Purpose |
|----------|:-:|---------|
| `VEHICLE` | yes | Top-level vehicle module (`Ovcs1`, `OvcsMini`, `Obd2`) — selects the VMS composer wired into the supervision tree |
| `CAN_NETWORK_MAPPINGS` | no | Override the vehicle's `default_can_mapping(:host)` (format: `name:iface,name:iface,...`) |

## Dependencies

Direct path dep: [`vms_core`](../core). Cantastic / OvcsBus / OvcsCan
come in transitively through `vms_core`. The active vehicle package
under `vehicles/<name>/` isn't a Mix dep — it's resolved at runtime
from `VEHICLE` by `vms/firmware/config/runtime.exs` (via
`OvcsVehicle.Firmware.resolve_vehicle/3`) before `VmsCore.Application`
starts.
