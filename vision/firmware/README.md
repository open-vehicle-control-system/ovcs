# Vision Firmware

Nerves firmware image for a vehicle's vision unit. Wraps
[`vision_api`](../api) (and through it [`vision_core`](../core), the
dashboard build and the active vehicle package) into a deployable image
for the Raspberry Pi 5.

## Target

`MIX_TARGET`: `rpi5`, built on the
[`ovcs_bridges_system_rpi5`](https://github.com/open-vehicle-control-system/ovcs_bridges_system_rpi5)
system, which ships libcamera with the PiSP pipeline and the Hailo-8
driver. `libhailort` comes from [`libraries/hailort`](../../libraries/hailort).

Compiling `vision_core` for `rpi5` cross-builds the `camera_capture` and
`hailo_detect` Port binaries from [`../rust`](../rust) into its `priv/`
(see `../core/Makefile`). That needs the `aarch64-unknown-linux-gnu` Rust
target (installed by `mise install`) and a host libclang for bindgen.

Per-target defaults (`fwup.conf`, `config.txt`, `cmdline-a.txt`,
`cmdline-b.txt`) live under `targets/rpi5/`. A vehicle overrides
`fwup.conf` by dropping its own into `vehicles/<name>/priv/firmware/vision/`.
The boot files are taken as a set: once that directory holds a
`config.txt`, `config.txt`, `cmdline-a.txt` and `cmdline-b.txt` are all
read from it.

The image's hostname is `<vehicle>-vision` (e.g. `ovcs-mini-vision`), its
product name `<Vehicle Name> - Vision`, and the dashboard and API listen
on port 4100.

## Building

Preferred, from the repo root:

```sh
./ovcs build  <vehicle> vision
./ovcs burn   <vehicle> vision
./ovcs upload <vehicle> vision [--host HOST] [--file FILE]
./ovcs clean  <vehicle> vision
```

The vehicle must implement `vision/0` and `vision_target/0`. The release
fails when a file the vision composer lists in `required_files/0` (a
detection model, for instance) is missing from the vehicle app.

`build.sh` requires `VEHICLE` and defaults `MIX_TARGET` to `rpi5`. It
builds the dashboard (`../dashboard`) into `vision_api`'s `priv/static`,
then runs `mix firmware`.

## Required env vars

| Variable | Required | Purpose |
|----------|:-:|---------|
| `VEHICLE` | yes | Top-level vehicle module (`OvcsMini`, …). `config/runtime.exs` resolves its vision composer with `OvcsVehicle.Firmware.resolve_side/4` and writes it to `:vision_core, :vehicle` |
| `MIX_TARGET` | no | Nerves target atom (default: `rpi5`) |
| `NERVES_FW_APPLICATION_PART0_TARGET` | no | Application partition mount point (default: `/data`) |

`AUTHORIZED_SSH_KEYS`, `SECRET_KEY_BASE`, `ZENOH_ENDPOINT_IP`, `WIFI_NETWORKS`
and the NervesHub settings live in `vehicles/<vehicle>/.env.exs`
(gitignored, copied from `.env.exs.example`) and are read by `target.exs`
at compile time.
