# Vision Firmware

Nerves firmware image for a vehicle's vision unit. Wraps
[`vision_api`](../api) (and through it [`vision_core`](../core), the
dashboard build and the active vehicle package) into a deployable image
for a Raspberry Pi 5 or an OKdo Nano C100.

## Targets

`MIX_TARGET` is `rpi5` or `okdo_c100`; `./ovcs` sets it from the
vehicle's `vision_target/0`.

| Target | Board | System |
|---|---|---|
| `rpi5` | Raspberry Pi 5, optionally with a Hailo-8 | [`ovcs_bridges_system_rpi5`](https://github.com/open-vehicle-control-system/ovcs_bridges_system_rpi5): libcamera with the PiSP pipeline, and the Hailo-8 driver |
| `okdo_c100` | OKdo Nano C100 | [`nerves_system_okdo_c100`](https://github.com/Spin42/nerves_system_okdo_c100): the CSI camera drivers, and Mesa NVK for Vulkan |

Compiling `vision_core` for a target cross-builds that target's Port
binaries from [`../rust`](../rust) into its `priv/` (see
`../core/Makefile`): `camera_capture`, `hailo_detect`, `jpeg_codec` and
`stereo_match` for `rpi5`, `v4l2_capture` and `jpeg_codec` for
`okdo_c100`. That needs the `aarch64-unknown-linux-gnu` Rust target
(installed by `mise install`), and for `rpi5` a host libclang for
bindgen and `libhailort`, which comes from
[`libraries/hailort`](../../libraries/hailort).

Per-target defaults (`fwup.conf`, `config.txt`, `cmdline-a.txt`,
`cmdline-b.txt`) live under `targets/rpi5/`; `okdo_c100` has none and
uses its system's `fwup.conf`. A vehicle overrides `fwup.conf` by
dropping its own into `vehicles/<name>/priv/firmware/vision/`. The boot
files are taken as a set: once that directory holds a `config.txt`,
`config.txt`, `cmdline-a.txt` and `cmdline-b.txt` are all read from it.

The image's hostname is `<vehicle>-vision`, every underscore of the
vehicle's directory name turned into a dash. Its product name is
`<Vehicle Name> - Vision`, and the dashboard and API listen on port
4100.

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
| `VEHICLE` | yes | Top-level vehicle module (`<Vehicle>`). `config/runtime.exs` resolves its vision composer with `OvcsVehicle.Firmware.resolve_side/4` and writes it to `:vision_core, :vehicle` |
| `MIX_TARGET` | no | Nerves target atom, `rpi5` or `okdo_c100` (default: `rpi5`) |
| `NERVES_FW_APPLICATION_PART0_TARGET` | no | Application partition mount point (default: `/data`) |

`AUTHORIZED_SSH_KEYS`, `SECRET_KEY_BASE`, `ZENOH_ENDPOINT_IP`, `WIFI_NETWORKS`
and the NervesHub settings live in `vehicles/<vehicle>/.env.exs`
(gitignored, copied from `.env.exs.example`) and are read by `target.exs`
at compile time.
