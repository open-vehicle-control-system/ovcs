# ROS 2 stack

Docker Compose harness for running ROS 2 Jazzy + the Zenoh router on
the on-vehicle Pi (or any dev box). Uses `rmw_zenoh_cpp` so ROS nodes
join the same Zenoh fabric the Elixir `ros_bridge` already speaks to
— no DDS, no multicast, just TCP peerings to `zenohd`.

Two services:

- `zenohd` — the Zenoh router. Listens on `tcp/0.0.0.0:7447` via host
  networking, so any peer on the LAN (e.g. the Nerves bridges) can
  connect by pointing at this host's IP.
- `ros2` — `ros:jazzy-ros-base` with `RMW_IMPLEMENTATION=rmw_zenoh_cpp`,
  configured to peer with `zenohd` at `tcp/${ZENOH_ENDPOINT_IP}:7447`
  (defaults to `127.0.0.1`, i.e. the bundled router).
- `foxglove_bridge` — `ros-jazzy-foxglove-bridge` exposing a WebSocket
  on port `8765` so [Foxglove Studio](https://foxglove.dev) can attach.
  Same `rmw_zenoh_cpp` config as `ros2`, so anything on the OVCS bus
  is visible. Connect Studio to `ws://<host-ip>:8765`.
- `joy` — `ros-jazzy-joy-linux` reading a USB game controller from
  `/dev/input/js0` (override with `JOY_DEV`) and publishing
  `sensor_msgs/Joy` on `/joy`. The OVCS `RosBridge.Consumers.Joy`
  subscribes to the same topic, so the controller drives
  steering/throttle on the CAN bus end-to-end.

## Quick start

```sh
cp .env.example .env           # set ZENOH_ENDPOINT_IP for your router
docker compose up -d
docker compose exec ros2 bash  # shell with ROS env pre-sourced
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
Foxglove against `ws://<host>:8765`.

### USB controller → `/joy` → CAN

Plug an Xbox (or generic HID) controller into the host, then:

```sh
ls /dev/input/js*               # should show js0 — that's your default
docker compose up -d joy        # builds the joy image on first run

docker compose exec ros2 bash -lc '
  source /opt/ros/jazzy/setup.bash
  ros2 topic echo /joy sensor_msgs/msg/Joy   # wiggle a stick to confirm
'
```

The OVCS `RosBridge.Consumers.Joy` subscribes to `/joy` over the same
Zenoh fabric, so a running `./ovcs run <vehicle>` (or a Nerves bridge
on the LAN) will see axes flow straight into the `ros_control1` CAN
emitter — no extra config.

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

## Files

- `docker-compose.yml` — declarative service definitions only (no
  inline shell). Four services share one image: `zenohd` (the
  upstream Zenoh router), plus `ros2` + `foxglove_bridge` + `joy`,
  all running `ovcs/ros2:jazzy`. The `ros2` service is the one that
  builds the image; the others reference it by tag. A YAML anchor
  (`x-ros2-base`) factors out the env / volumes / network they all
  share — per-service entries only declare what differs (CMD, extra
  env, extra volumes, device wiring).
- `Dockerfile` — single image baking `ros-jazzy-rmw-zenoh-cpp`,
  `ros-jazzy-foxglove-bridge`, `ros-jazzy-joy-linux`, `gettext-base`,
  and the Python `eclipse-zenoh` client. Sets a proper `ENTRYPOINT`
  + default `CMD`; per-service launchers are picked via compose's
  `command:` field. Rebuild after changing it: `docker compose build`.
- `docker/` — shell scripts baked into the image:
  - `entrypoint.sh` — shared `ENTRYPOINT`. Renders
    `zenoh/session.json5` from the template, sources the ROS overlay,
    then `exec "$@"`. Service-agnostic.
  - `foxglove_bridge.sh`, `joy.sh` — per-service launcher scripts
    (installed at `/usr/local/bin/foxglove_bridge` and
    `/usr/local/bin/joy` respectively). The `ros2` service uses the
    default CMD (`tail -f /dev/null`), so no script is needed.
- `zenoh/session.json5` — Zenoh session config (client mode, connects
  to `tcp/${ZENOH_ENDPOINT_IP}:7447`, multicast scouting disabled).
- `workspace/` — bind-mounted into the container at `/workspace`;
  drop ROS 2 packages / overlays here. Not gitignored — add as needed.

## Notes

- `network_mode: host` is used so Zenoh's local-discovery and any
  `roscli`/`ros2 daemon` tooling behave the same as a bare-metal install.
- The compose service installs `ros-jazzy-rmw-zenoh-cpp` on first
  start (the upstream image doesn't ship it). For a stateless / power-
  loss-safe deploy, bake a custom image with it preinstalled.
- This compose stack is the dev/throwaway path. Production deploy
  story (Ubuntu Core + ROS snap, or read-only Ubuntu + this compose
  on tmpfs overlay) is still TBD — see the conversation log.
