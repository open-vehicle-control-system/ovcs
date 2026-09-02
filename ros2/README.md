# ROS 2 stack

ROS 2 Jazzy + the Zenoh router, split across the two machines that run
it. Uses `rmw_zenoh_cpp` so ROS nodes join the same Zenoh fabric the
Elixir `ros_bridge` already speaks to — no DDS, no multicast, just TCP
peerings to `zenohd`.

```
ros2/
├── vehicule/          on-vehicle stack, deployed to balenaOS
│   ├── docker-compose.yml
│   ├── image/         the shared ROS 2 image (Dockerfile + launchers)
│   ├── firmware/      Wi-Fi firmware staged into the host kernel
│   └── host/          balenaOS network config (not deployed by push)
└── base/              base-station stack, plain docker compose
    ├── docker-compose.yml
    ├── calibrate.sh
    └── workspace/     scratch ROS packages (gitignored)
```

The vehicle is the router. `zenohd` runs on the ROS compute Pi, so the
fabric survives the base station disconnecting; the Nerves bridges, the
on-vehicle nodes, and the base station all join it as clients. See
[docs/ros_compute_node.md](../docs/ros_compute_node.md) for the
hardware, the OS, and the deployment story.

## Who runs what

| Service | Side | Why |
|---|---|---|
| `zenohd` | vehicule | the fabric must outlive the operator's laptop |
| `foxglove_bridge` | vehicule | Studio attaches over the LAN to `ws://<pi>:8765` |
| autonomy / perception nodes | vehicule | they drive the car |
| `ros2` (tooling shell) | base | interactive, `docker compose exec` |
| `joy` | base | the game controller is with the operator, not the car |
| `calibrator` | base | one-shot X11 GUI |

`base/` also carries `standalone` copies of `zenohd` and
`foxglove_bridge` behind a compose profile, for developing with no
vehicle on the LAN.

Both sides run the **same image**, built from `vehicule/image/`. It
lives on the vehicle side because balena requires every build context
to sit inside the pushed source root; the base station reaches across
to it (`context: ../vehicule/image`), which plain `docker compose` is
happy to do.

## Base station

```sh
cd ros2/base
cp .env.example .env               # ZENOH_ENDPOINT_IP → the vehicle's ROS Pi
docker compose up -d
docker compose exec ros2 bash      # shell with ROS env pre-sourced
```

Smoke-test against the bridge's heartbeat (published by
`RosBridge.ZenohClient` on the rmw_zenoh topic `/ovcs_heartbeat`):

```sh
docker compose exec ros2 bash -lc '
  source /opt/ros/jazzy/setup.bash
  ros2 topic list                              # should include /ovcs_heartbeat
  ros2 topic echo /ovcs_heartbeat std_msgs/msg/String
'
```

The actual Zenoh keyexpr is namespaced by `rmw_zenoh`
(`0/ovcs_heartbeat/std_msgs::msg::dds_::String_/RIHS01_…`), so a bare
`z_sub -k ovcs_heartbeat` will not match. Use the ROS 2 CLI (above) or
Foxglove against `ws://<vehicle-ip>:8765`.

With no vehicle on the LAN, bring up a local router and bridge instead:

```sh
ZENOH_ENDPOINT_IP=127.0.0.1 docker compose --profile standalone up -d
```

### USB controller → `/joy` → CAN

Plug an Xbox (or generic HID) controller into the base station, then:

```sh
ls /dev/input/js*               # should show js0 — that's your default
docker compose up -d joy

docker compose exec ros2 bash -lc '
  source /opt/ros/jazzy/setup.bash
  ros2 topic echo /joy sensor_msgs/msg/Joy   # wiggle a stick to confirm
'
```

`RosBridge.Consumers.Joy` subscribes to `/joy` over the same Zenoh
fabric, so a running `./ovcs run <vehicle>` (or a Nerves bridge on the
LAN) will see axes flow straight into the `ros_control1` CAN emitter —
no extra config, and the controller stays in the operator's hands.

Other controllers / non-default device:

```sh
JOY_DEV=/dev/input/js1 docker compose up -d joy
# Or set deadzone / autorepeat:
JOY_DEADZONE=0.1 JOY_AUTOREPEAT_RATE=50 docker compose up -d joy
```

Notes:

- The host kernel's `xpad` driver creates `/dev/input/jsN` for Xbox
  controllers out of the box on Ubuntu. If `ls /dev/input/js*` is
  empty after plugging in, check `dmesg | tail`.
- `/dev/input` is bind-mounted (not declared as `devices:`) and a
  cgroup rule for char-major 13 is added, so hot-plugged controllers
  appear in the container without a restart.
- The service is Linux-only — `device_cgroup_rules` + bind-mounted
  `/dev/input` does not work on Docker Desktop for macOS/Windows.

## Vehicle

```sh
cd ros2/vehicule
balena push ovcs-mini-ros          # build on balena's builders + OTA
balena push <device>.local         # local mode, no cloud round-trip
```

Runtime configuration comes from balena fleet/device variables, not a
`.env` file. `docker compose up -d` from the same directory also works
for a bare-metal rehearsal on any aarch64 box.

The vehicle compose file deliberately avoids YAML anchors, `${VAR:-…}`
interpolation, `container_name`, `profiles:`, `device_cgroup_rules`,
host bind mounts, and the shared-image-tag pattern — the balena
supervisor implements only a subset of Compose v2. The header comment
in that file lists each omission and why.

## Files

- `vehicule/docker-compose.yml` — the balena stack: `zenohd` +
  `foxglove_bridge`, each with its own `build:` (the balena builder
  tags per service, so one service can't reference another's tag).
  Autonomy nodes join here as additional services.
- `vehicule/firmware/Dockerfile` — one-shot service that stages the
  AX210's `iwlwifi` blobs into balenaOS's `extra-firmware` volume.
  balenaOS ships the driver but not firmware this new, so without it
  the PCIe Wi-Fi card never binds and the access point cannot exist.
- `vehicule/host/` — NetworkManager keyfile templates that make the Pi
  the vehicle's access point, DHCP server and gateway. Host-OS config,
  copied to the device once; `balena push` does not deploy it. See
  [docs/ros_compute_node.md](../docs/ros_compute_node.md#networking).
- `vehicule/image/Dockerfile` — single image baking
  `ros-jazzy-rmw-zenoh-cpp`, `ros-jazzy-foxglove-bridge`,
  `ros-jazzy-joy-linux`, `gettext-base`, the Python `eclipse-zenoh`
  client, and the Zenoh session template. Sets a proper `ENTRYPOINT` +
  default `CMD`; per-service launchers are picked via compose's
  `command:` field. Rebuild after changing it: `docker compose build`
  from `base/`, or `balena push` for the vehicle.
- `vehicule/image/docker/` — shell scripts baked into the image:
  - `entrypoint.sh` — shared `ENTRYPOINT`. Renders
    `zenoh-session.json5` from the baked template, sources the ROS
    overlay, then `exec "$@"`. Service-agnostic.
  - `foxglove_bridge.sh`, `joy.sh`, `calibrator.sh` — per-service
    launchers (installed at `/usr/local/bin/<name>`). The `ros2`
    service uses the default CMD (`tail -f /dev/null`).
- `vehicule/image/zenoh/session.json5.template` — Zenoh session config
  (client mode, connects to `tcp/${ZENOH_ENDPOINT_IP}:7447`, multicast
  scouting disabled). Copied into the image at
  `/etc/zenoh/session.json5.template` rather than bind-mounted —
  balenaOS has no host bind mounts, and one mechanism means both sides
  read the identical file. Editing it means a rebuild.
- `base/docker-compose.yml` — the operator-side stack. Declarative
  service definitions only (no inline shell); a YAML anchor
  (`x-ros2-base`) factors out the env / network they share.
- `base/calibrate.sh`, `base/calibration_output/` — stereo calibration
  launcher and its output directory. See
  [calibration_output/README.md](./base/calibration_output/README.md).
- `base/workspace/` — bind-mounted into the container at `/workspace`;
  drop ROS 2 packages / overlays here while iterating. Gitignored. A
  node that graduates to running on the car gets baked into an image
  under `vehicule/` instead — the vehicle has no bind mounts.

## Notes

- `network_mode: host` is used on both sides so Zenoh's local
  discovery and any `ros2 daemon` tooling behave the same as a
  bare-metal install.
- The Nerves bridges' `ZENOH_ENDPOINT_IP` is **baked in at firmware
  build time** (`bridges/firmware/config/target.exs`), so the ROS Pi
  needs a static address and repointing it means rebuilding and
  re-uploading every bridge firmware.
- `zenohex 0.9.0` (used by `ros_bridge`) pins zenoh **1.9.0**, the same
  version as the `eclipse/zenoh:1.9.0` router image. Keep them together
  when bumping either.
