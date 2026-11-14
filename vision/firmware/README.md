# Vision Firmware

Nerves firmware image for a vehicle's vision unit. Wraps
[`vision_api`](../api) (and through it [`vision_core`](../core), the
dashboard build and the active vehicle package) into a deployable image
for a Raspberry Pi 5, an OKdo Nano C100 or an Arduino VENTUNO Q.

## Targets

`MIX_TARGET` is `rpi5`, `okdo_c100` or `arduino_ventuno_q`; `./ovcs`
sets it from the
vehicle's `vision_target/0`.

| Target | Board | System |
|---|---|---|
| `rpi5` | Raspberry Pi 5, optionally with a Hailo-8 | [`ovcs_bridges_system_rpi5`](https://github.com/open-vehicle-control-system/ovcs_bridges_system_rpi5): libcamera with the PiSP pipeline, and the Hailo-8 driver |
| `okdo_c100` | OKdo Nano C100 | [`nerves_system_okdo_c100`](https://github.com/Spin42/nerves_system_okdo_c100): the CSI camera drivers, and Mesa NVK for Vulkan |
| `arduino_ventuno_q` | Arduino VENTUNO Q | [`nerves_system_arduino_ventuno_q`](https://github.com/Spin42/nerves_system_arduino_ventuno_q): CAMSS for the CSI cameras, Mesa Turnip for Vulkan, and FastRPC for the NPU |

Compiling `vision_core` for a target cross-builds that target's Port
binaries from [`../rust`](../rust) into its `priv/` (see
`../core/Makefile`):

- `rpi5`: `camera_capture`, `hailo_detect`, `jpeg_codec` and
  `stereo_match`;
- `okdo_c100`: `v4l2_capture` and `jpeg_codec`;
- `arduino_ventuno_q`: those two, `qnn_detect` and `qnn_segment`.

That needs:

- the `aarch64-unknown-linux-gnu` Rust target, installed by
  `mise install`;
- a host libclang for bindgen on `rpi5` and `arduino_ventuno_q`;
- `libhailort` for `rpi5`, which comes from
  [`libraries/hailort`](../../libraries/hailort);
- for `arduino_ventuno_q`, the QAIRT archive `mise run fetch-qairt`
  caches.

The `qnn` crate's QNN bindings, which `qnn_detect` and `qnn_segment`
share, are generated from the archive's QNN headers at build time.
Nothing derived from them is committed.

Per-target defaults (`fwup.conf`, `config.txt`, `cmdline-a.txt`,
`cmdline-b.txt`) live under `targets/rpi5/`; `okdo_c100` and
`arduino_ventuno_q` have none and use their system's `fwup.conf`. A
vehicle overrides `fwup.conf` by dropping its own into
`vehicles/<name>/priv/firmware/vision/`. The boot files are taken as a
set: once that directory holds a `config.txt`, `config.txt`,
`cmdline-a.txt` and `cmdline-b.txt` are all read from it.

The root filesystem takes up to three overlays, later ones winning: the
firmware's `rootfs_overlay/`, the vehicle's
`priv/firmware/vision/rootfs_overlay/` (the VENTUNO Q's
`/boot/cameras.cfg`, which names the sensor on each CSI connector), and
`rootfs_overlay_qairt/`, where `mise run fetch-qairt` writes QAIRT as
`/opt/qairt`. Run it with `VEHICLE` set; QAIRT's licence allows shipping
it only inside a firmware, so no repository carries it. On
`arduino_ventuno_q` only, erlinit sets `IREE_HAL_VULKAN_SLAB_SIZE` to
512 MiB.

The image's hostname is `<vehicle>-vision`, every underscore of the
vehicle's directory name turned into a dash. Its product name is
`<Vehicle Name> - Vision`, and the dashboard and API are served over
HTTPS on port 443, with a self-signed certificate the unit generates
in `/data/vision_api/` at its first start. Ports 80 and 4100 redirect
plain HTTP there.

When `vision_core`, `vision_api` or the firmware's own application
exits, or does not start, `VisionFirmware.ShoehornHandler` starts those
that do not run again, after a wait that doubles from a second to a
minute, for as long as they exit: the unit does not reboot itself. An
exit after five minutes of running waits a second again. SSH and the
firmware updates start before these applications and keep running
meanwhile, so a unit whose vision keeps failing stays reachable.

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
| `MIX_TARGET` | no | Nerves target atom, `rpi5`, `okdo_c100` or `arduino_ventuno_q` (default: `rpi5`) |

`AUTHORIZED_SSH_KEYS`, `SECRET_KEY_BASE`, `ZENOH_ENDPOINT_IP`, `WIFI_NETWORKS`
and the NervesHub settings live in `vehicles/<vehicle>/.env.exs`
(gitignored, copied from `.env.exs.example`) and are read by `target.exs`
at compile time.
