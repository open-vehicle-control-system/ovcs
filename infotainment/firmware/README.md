# Infotainment Firmware

Nerves firmware image for the in-car touchscreen. Wraps
[`infotainment_api`](../api) (and transitively
[`infotainment_core`](../core) + the active vehicle package's infotainment
side) into a deployable image for the Raspberry Pi 5 head unit.

Only built for vehicles that expose an `infotainment/0` composer — vehicles
without a head unit (e.g. `OvcsMini`, `Obd2`) skip this layer entirely.

See [`docs/components.md`](../../docs/components.md) for how this layer
fits with `core` / `api` / `dashboard`, and
[`docs/running_hardware.md`](../../docs/running_hardware.md) for burn + OTA
flows.

## Target

Default `MIX_TARGET`: `ovcs_base_can_system_rpi5` — a
[custom Nerves system](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi5)
with CAN + display support.

Per-target defaults (`fwup.conf`, `config.txt`, `cmdline-a.txt`,
`cmdline-b.txt`) live under `targets/<target>/`. A vehicle overrides
`fwup.conf` by dropping its own into `vehicles/<name>/priv/firmware/infotainment/`.
The boot files are taken as a set: once that directory holds a
`config.txt`, `config.txt`, `cmdline-a.txt` and `cmdline-b.txt` are all
read from it, so a vehicle overriding one ships all three.

## Flutter app bundling

The Flutter dashboard (`../dashboard`) is built **during release
assembly**, not before. `nerves_flutter_support` hooks a `mix release` step
that cross-compiles the Flutter app for the target and embeds the output
in the firmware. This keeps `build.sh` a single `mix deps.get` +
`mix firmware` — no separate Flutter step.

## Building

Preferred, from the repo root:

```sh
./ovcs build ovcs1 infotainment
./ovcs burn   ovcs1 infotainment
./ovcs upload ovcs1 infotainment [--host HOST] [--file FILE]
./ovcs clean  ovcs1 infotainment
```

The CLI reads `infotainment_target/0` off the vehicle module and
passes it as `MIX_TARGET`, then delegates to `build.sh` / `burn.sh` /
`upload.sh` / `clean.sh` in this directory.

Direct invocation also works — `build.sh` requires `VEHICLE` and defaults
`MIX_TARGET` to `ovcs_base_can_system_rpi5`. The resulting `.fw` lands in
`_build/${MIX_TARGET}_dev/nerves/images/`.

## Required env vars

| Variable | Required | Purpose |
|----------|:-:|---------|
| `VEHICLE` | yes | Top-level vehicle module (`Ovcs1`, …) — picked up by `infotainment/firmware/config/runtime.exs` via `OvcsVehicle.Firmware.resolve_side/4`, which writes the infotainment composer to `:infotainment_core, :vehicle` before `InfotainmentCore.Application` starts |
| `MIX_TARGET` | no | Nerves target atom (default: `ovcs_base_can_system_rpi5`) |
| `NERVES_FW_APPLICATION_PART0_TARGET` | no | Application partition mount point (default: `/data` — see `vms/firmware/README.md`) |

`AUTHORIZED_SSH_KEYS`, `SECRET_KEY_BASE`, `SIGNING_SALT`, etc. live in
`vehicles/<vehicle>/.env.exs` (gitignored).
