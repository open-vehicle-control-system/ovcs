# VMS Firmware

Nerves firmware image for the Vehicle Management System. Wraps
[`vms_api`](../api) (and transitively [`vms_core`](../core) + the active
vehicle package) into a deployable image for the Raspberry Pi 4.

See [`docs/applications.md`](../../docs/applications.md) for how this layer
fits with `core` / `api` / `dashboard`, and
[`docs/running_hardware.md`](../../docs/running_hardware.md) for burn + OTA
flows.

## Target

Default `MIX_TARGET`: `ovcs_base_can_system_rpi4` — a
[custom Nerves system](https://github.com/open-vehicle-control-system/ovcs_base_can_system_rpi4)
with CAN bus support (SPI-to-CAN) and the kernel modules the VMS needs.

Per-target defaults (`fwup.conf`, `config.txt`, `cmdline.txt`) live under
`targets/<target>/`. A vehicle can override any of them by dropping files
into its own `vehicles/<name>/priv/firmware/vms/`; the build prefers the
per-vehicle file when present.

## Building

Preferred, from the repo root:

```sh
./ovcs build ovcs1 vms          # also: ovcs_mini, any vehicle dir
./ovcs burn   ovcs1 vms         # write to SD card
./ovcs upload ovcs1 vms [--host HOST] [--file FILE]
./ovcs clean  ovcs1 vms
```

The CLI resolves the vehicle module, sets `VEHICLE` + `MIX_TARGET` (reading
`nerves_target(:vms)` off the vehicle module), and delegates to `build.sh`
/ `burn.sh` / `upload.sh` / `clean.sh` in this directory.

Invoking the scripts directly also works — `build.sh` requires `VEHICLE`
and defaults `MIX_TARGET` to `ovcs_base_can_system_rpi4`. It builds the
Vue.js dashboard (`../dashboard`) first, then runs `mix firmware`. The
resulting `.fw` lands in `_build/${MIX_TARGET}_dev/nerves/images/`.

## Required env vars

| Variable | Required | Purpose |
|----------|:-:|---------|
| `VEHICLE` | yes | Top-level vehicle module (`Ovcs1`, `OvcsMini`, …) — picked up by `vms_api`'s `config/runtime.exs` and wired into the supervision tree |
| `MIX_TARGET` | no | Nerves target atom (default: `ovcs_base_can_system_rpi4`) |

## Changing hardware target

Edit `mix.exs` to swap the custom system dep if you need to deploy on a
different board. Follow the
[Nerves custom-systems guide](https://hexdocs.pm/nerves/customizing-systems.html)
and see `docs/running_hardware.md` for the list of systems OVCS publishes.
