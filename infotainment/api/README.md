# Infotainment API

Phoenix 1.7 JSON + WebSocket server for the in-car touchscreen. Same shape
as [`vms_api`](../../vms/api) — a thin routing layer in front of
[`infotainment_core`](../core) — but serves the Flutter dashboard
(`../dashboard`) on the RPi 5 head unit instead of the Vue debug UI.

See [`docs/applications.md`](../../docs/applications.md) for where this
layer fits in the overall `core` / `api` / `firmware` / `dashboard` stack.

## Endpoints

### REST

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/api/vehicle` | Vehicle metadata |
| `GET` | `/api/vehicle/pages` | Page list driving the touchscreen nav |
| `GET` | `/api/vehicle/pages/:page_id/blocks` | Blocks rendered on a given page |
| `POST` | `/api/actions` | Dispatch a UI action (gear change, settings toggle, …) |

Layout is supplied by the active vehicle's composer
(`<Vehicle>.Infotainment.Composer.infotainment_configuration/0`).

### WebSocket

Phoenix socket mounted at `/sockets/dashboard`. Channel:

| Topic | Purpose |
|-------|---------|
| `metrics` | Streams metric updates for `{module, key}` pairs the client subscribes to |

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
| `VEHICLE` | yes | Top-level vehicle module (`Ovcs1`, `OvcsMini`, …). The vehicle's `infotainment/0` must return an `InfotainmentCore.Vehicle` composer — vehicles with no head unit (e.g. `OvcsMini`, `Obd2`) don't boot this app |
| `CAN_NETWORK_MAPPINGS` | no | Override the vehicle's `default_can_mapping(:host)` |

## Dependencies

Path deps: [`infotainment_core`](../core), [`cantastic`](../../libraries/cantastic),
[`ovcs_can`](../../libraries/ovcs_can), [`ovcs_bus`](../../libraries/ovcs_bus),
[`ovcs_vehicle`](../../libraries/ovcs_vehicle). The active vehicle package
under `vehicles/<name>/` is resolved at runtime from `VEHICLE`.
