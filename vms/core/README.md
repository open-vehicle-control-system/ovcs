# VMS Core

`VmsCore`, the core of the Vehicle Management System: component drivers, managers, metrics and the `VmsCore.Vehicle` behaviour a vehicle's VMS composer implements. The guides, [VMS](../../docs/vms/README.md) and [How the VMS works](../../docs/vms/how_it_works.md), explain what it does and how; this README keeps the library's developer details.

## Layout

```text
lib/vms_core/
├── application.ex        supervision tree: Repo, Metrics, NetworkInterfaces, OvcsBus.Cluster, the composer's children
├── vehicle.ex            the VmsCore.Vehicle behaviour
├── components/           one directory per manufacturer, one module per driver
├── managers/             ControlLevel, Gear
├── metrics.ex, status.ex, network_interfaces.ex, normalised_request.ex, repo.ex
└── models/               Ecto schemas
```

## Components

One directory per manufacturer under `lib/vms_core/components/`, one module per driver. [Drivers](../../docs/vms/drivers.md) lists them with their networks, options and what they publish; each module's moduledoc is the reference.

## Infrastructure Modules

| Module | File | Purpose |
|--------|------|---------|
| `VmsCore.Status` | `status.ex` | Emits VMS heartbeat (`0x1A0`), manages ready-to-drive state, controller reset command (`0x1AA`) |
| `VmsCore.Metrics` | `metrics.ex` | Subscribes to all Bus messages, stores latest values, exposes `metrics/0` for the API |
| `VmsCore.NormalisedRequest` | `normalised_request.ex` | Arithmetic on requests normalised to [-1, 1] |
| `VmsCore.Repo` | `repo.ex` | Ecto SQLite3 repository for persistent data |
| `VmsCore.NetworkInterfaces` | `network_interfaces.ex` | CAN interface statistics (TX/RX errors, bus state) |

## Running Locally

```sh
cd vms/api
VEHICLE=Ovcs1 iex -S mix phx.server
```

This runs the OVCS1 reference vehicle; set `VEHICLE` to your vehicle's top-level module the same way. The VMS Core starts as a dependency of the VMS API (Phoenix). The `VEHICLE` env var is required; `CAN_NETWORK_MAPPINGS` defaults to whatever `default_can_mapping(:host)` returns on the vehicle's VMS composer and only needs to be set to override it.

## License

See [`LICENCE.txt`](../../LICENCE.txt) at the repo root.
