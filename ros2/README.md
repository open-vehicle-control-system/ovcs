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

## Quick start

```sh
cp .env.example .env           # set ZENOH_ENDPOINT_IP for your router
docker compose up -d
docker compose exec ros2 bash  # shell with ROS env pre-sourced
```

Smoke-test against the bridge's heartbeat (published by
`RosBridge.ZenohClient` on key `ovcs/heartbeat`):

```sh
docker compose exec ros2 bash -lc \
  'apt-get -qq install -y zenoh-tools && z_sub -k ovcs/heartbeat'
```

## Files

- `docker-compose.yml` — `zenohd` (router) + `ros2` + `foxglove_bridge`
  services. The `ros2` service idles by default; replace the `command:`
  tail with `ros2 launch …` when you have actual nodes.
- `dockerfiles/` — `ros2.Dockerfile` and `foxglove_bridge.Dockerfile`
  bake `ros-jazzy-rmw-zenoh-cpp`, `ros-jazzy-foxglove-bridge`, and
  `gettext-base` into the images so containers start cold without an
  apt round-trip. Rebuild after changing them: `docker compose build`.
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
