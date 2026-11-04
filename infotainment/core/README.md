# Infotainment Core

Platform library for the in-car touchscreen UI. Mirrors [`vms_core`](../../vms/core)'s
role on the infotainment side: defines the vehicle contract, holds the
infotainment-only supporting modules, and owns the page/block model the
Flutter dashboard renders.

No vehicle-specific code lives here — each vehicle that ships an
infotainment head unit plugs into this library via its own composer
(`<Vehicle>.Infotainment.Composer`) implementing `InfotainmentCore.Vehicle`.

The guide, [Infotainment](../../docs/infotainment/README.md), explains the role, the
`InfotainmentCore.Vehicle` contract and the pages; this README keeps the library's
developer details.

## Modules

| Module | File | Purpose |
|--------|------|---------|
| `InfotainmentCore.Application` | `application.ex` | Starts `InfotainmentCore.Repo` + `Ecto.Migrator`, `Temperature`, `TimeSettings`, `OvcsBus.Cluster`, and the active vehicle's `children/0` |
| `InfotainmentCore.Vehicle` | `vehicle.ex` | The behaviour a vehicle's infotainment composer implements |
| `InfotainmentCore.LayoutValidator` | `layout_validator.ex` | Validates page/block layout maps before they hit the API |
| `InfotainmentCore.Temperature` | `temperature.ex` | The board's temperature, read from `thermal_zone0` on request |
| `InfotainmentCore.TimeSettings` | `time_settings.ex` | Persists display-time preferences in SQLite |
| `InfotainmentCore.Repo` | `repo.ex` | Ecto SQLite3 repository for persisted settings |

## Page/block layout

`infotainment_configuration/0` returns the layout the API serves; [Pages](../../docs/infotainment/README.md#pages)
lists the block types the Flutter dashboard (`../dashboard`) renders. Adding a new
block type means updating both sides.

## Running

`infotainment_core` isn't started directly — it's a dep of
[`infotainment_api`](../api), which is itself pulled in by
`infotainment/firmware`. Use `./ovcs run <vehicle>` to spawn the full
set of firmware BEAMs for a vehicle, or `cd infotainment/api && VEHICLE=Ovcs1
mix phx.server` to run just this side.
