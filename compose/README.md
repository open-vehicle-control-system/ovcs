# Container stacks

Everything in this project that runs in a container, split by the one
question that decides where a file may live: **is it pushed to the
vehicle, or does it never leave a workstation?**

```
compose/
├── compute/          PUSHED TO BALENA — the vehicle's compute node, one deployable unit
│   ├── docker-compose.yml    the on-vehicle stack (name and place imposed by balena)
│   ├── images/               every image the car runs: ros2/, nav2/, wifi-firmware/
│   ├── nav2/                 Nav2 launch + parameters — baked on the car, mounted by the simulator
│   └── host/                 balenaOS network config (copied to the device once, never pushed)
└── local/            NEVER PUSHED — the operator's machine and the simulation workstation
    ├── common.yml            the shared service definitions the two stacks `extends:`
    ├── base.yml              operator laptop: ros2 shell, joy, calibrator, standalone router, nav2 profile
    ├── simulation.yml        Gazebo: sim, teleop, gz-gui, nav2 against the simulator
    ├── images/sim/           the Gazebo image — the only one that never goes near the car
    ├── simulation/           worlds, macros, launch files, gamepad mapping, test scripts
    ├── scripts/              the verifiers behind `mise run verify-*`, and calibrate.sh
    └── calibration_output/   where the stereo calibrator drops its tarball
```

`compute/` is a machine and `local/` is a place; neither is a
technology. A service on the vehicle that has nothing to do with ROS
(`wifi_firmware` already; telemetry or a bag recorder later) has a home
that needs no ROS justification, and a local-only tool is visibly
local-only. What the two halves share is the Zenoh fabric: ROS 2 nodes
use `rmw_zenoh_cpp`, the Elixir `ros_bridge` speaks the same wire
format natively, and everything is a client of one router — no DDS, no
multicast, just TCP peerings to `zenohd`.

## Who runs what

| Service | Where | Why |
|---|---|---|
| `zenohd` | compute | the fabric must outlive the operator's laptop |
| `foxglove_bridge` | compute | Studio attaches over the LAN to `ws://<compute-node-ip>:8765` |
| `nav2` | compute | the planner survives the base station leaving, like the router |
| `wifi_firmware` | compute | AX210 blobs for the host kernel — not ROS at all |
| `ros2` (tooling shell) | local/base | interactive, `docker compose exec` |
| `joy` | local/base | the game controller is with the operator, not the car |
| `calibrator` | local/base | one-shot X11 GUI |
| `sim`, `teleop`, `gz-gui` | local/simulation | Gazebo and its operator-side extras |

`local/base.yml` also carries `standalone` copies of `zenohd` and
`foxglove_bridge` behind a compose profile, and the car's Nav2 behind
another, for developing with no vehicle on the LAN. Two routers on one
LAN is how you end up debugging two fabrics — with a vehicle present,
leave those profiles off.

## Profiles

A service sits behind a profile for one of two mechanical reasons: it
**stands in for something the vehicle provides**, so it must not run
while a vehicle is on the LAN; or it has a **host dependency that would
make a plain `up -d` fail**. Nothing is behind a profile for tidiness.

| Stack | Profile | Adds | Reason |
|---|---|---|---|
| `base.yml` | *(none)* | `ros2`, `joy` | what an operator always wants with a vehicle present |
| `base.yml` | `standalone` | `zenohd`, `foxglove_bridge` | stands in for `compute/`; two routers on one LAN is two fabrics |
| `base.yml` | `nav2` | `nav2` (wall clock, container `ovcs-nav2-vehicle`) | stands in for the car's planner; two planners fight over `/cmd_vel_nav` |
| `base.yml` | `calibration` | `calibrator` | one-shot X11 GUI |
| `simulation.yml` | *(none)* | `sim` | headless Gazebo, what the verifiers rely on |
| `simulation.yml` | `nav2` | `nav2` (`use_sim_time:=true`, container `ovcs-nav2`) | the same image against the simulator's clock |
| `simulation.yml` | `teleop` | `teleop` | `devices: /dev/input/js0` fails `up` without a controller |
| `simulation.yml` | `gui` | `gz-gui` | needs an X socket |

The two `nav2` profiles are the same image with different clocks; start
one or the other, never both. The verifiers compose these explicitly —
`verify-nav2` wants the router without the vehicle's planner,
`verify-planner-loop` wants both — which is why they are not one
profile.

## The one link across the boundary

The images the car runs are built **only** from `compute/images/`:
balena requires every `build:` context inside the pushed directory,
and its builders cannot inherit from a local `ovcs/*` tag. The local
stacks reach across to build the very same Dockerfiles —
`context: ../compute/images/ros2` for the shared ROS image,
`context: ../compute` for Nav2 — so a workstation runs the bits the car
runs, never a copy of them. One Dockerfile, one tag, on both sides:

| Image | Dockerfile | Tag | Built by |
|---|---|---|---|
| shared ROS 2 | `compute/images/ros2/` | `ovcs/ros2:lyrical` | balena; `local/base.yml` (`ros2` service) |
| Nav2 | `compute/images/nav2/` | `ovcs/nav2:lyrical` | balena; `local/base.yml` and `local/simulation.yml` (`nav2`) |
| Wi-Fi firmware | `compute/images/wifi-firmware/` | — | balena only |
| Gazebo | `local/images/sim/` | `ovcs/sim:jetty` | `local/simulation.yml` only |

The same direction holds for Nav2's launch file and parameters:
`compute/nav2/` is baked into the onboard image and bind-mounted by the
simulator, so a simulated run exercises the configuration that ships.
The one difference is the clock, and it is a visible launch argument
(`use_sim_time:=true`).

## Starting each stack

Every local command is run from `compose/local/` and names its file:
the stacks are `base.yml` and `simulation.yml` rather than a
`docker-compose.yml` per directory, so `-f` is always spelled out. Each
carries its own project `name:` so the two never collide.

**Operator machine, with a vehicle on the LAN:**

```sh
cd compose/local
cp .env.example .env               # ZENOH_ENDPOINT_IP → the vehicle's compute node
docker compose -f base.yml up -d
docker compose -f base.yml exec ros2 bash   # shell with ROS env pre-sourced
```

Smoke-test against the bridge's heartbeat (published by
`RosBridge.ZenohClient` on `/ovcs_heartbeat`):

```sh
docker compose -f base.yml exec ros2 bash -lc '
  ros2 topic list                              # should include /ovcs_heartbeat
  ros2 topic echo /ovcs_heartbeat std_msgs/msg/String
'
```

The actual Zenoh keyexpr is namespaced by `rmw_zenoh`
(`0/ovcs_heartbeat/std_msgs::msg::dds_::String_/RIHS01_…`), so a bare
`z_sub -k ovcs_heartbeat` will not match. Use the ROS 2 CLI (above) or
Foxglove against `ws://<compute-node-ip>:8765`.

**Operator machine, no vehicle:**

```sh
ZENOH_ENDPOINT_IP=127.0.0.1 docker compose -f base.yml --profile standalone up -d
```

**USB controller → `/joy` → CAN:**

```sh
ls /dev/input/js*                            # should show js0 — that's the default
docker compose -f base.yml up -d joy
docker compose -f base.yml exec ros2 bash -lc 'ros2 topic echo /joy sensor_msgs/msg/Joy'
```

`RosBridge.Consumers.Joy` subscribes to `/joy` over the same fabric, so
a running `./ovcs run <vehicle>` (or a Nerves bridge on the LAN) sees
the axes flow straight into the `ros_actuator_command` CAN emitter.
Other controllers: `JOY_DEV=/dev/input/js1 docker compose -f base.yml up -d joy`;
`JOY_DEADZONE` and `JOY_AUTOREPEAT_RATE` likewise. The service is
Linux-only — `device_cgroup_rules` + a bind-mounted `/dev/input` does
not work on Docker Desktop for macOS/Windows; if `ls /dev/input/js*` is
empty after plugging in, check `dmesg | tail`.

**Foxglove Studio:** connect to `ws://<compute-node-ip>:8765` (or
`ws://127.0.0.1:8765` with the `standalone` profile), then *Layouts →
Import from file…* one of [`local/foxglove/`](./local/foxglove/):

| Layout | For | Shows |
|---|---|---|
| `ovcs_navigation.json` | the planner drive | both costmaps, global and local plan, footprint and odometry in the `odom` frame; commanded vs measured velocity; dead-reckoned position; IMU vs odometry yaw rate; the odometry stamp (silence there is what halts Nav2). Clicking in the 3D panel publishes a `/goal_pose`. |
| `ovcs_perception.json` | the stereo pipeline | left/right images with detection boxes, depth, point cloud with 3D detections, IMU and joystick plots |

Both are plain Studio exports: edit in Studio, export, overwrite the
file. They are operator tooling, which is why they live in `local/` and
not with the Elixir bridge that publishes the topics.

**Simulator:** see [`local/simulation/README.md`](./local/simulation/README.md).

**Vehicle:** see [`compute/README.md`](./compute/README.md) —
`balena push` from `compose/compute/`.

## Versions

The pins below have to move together. CI (`pins` job in
`.github/workflows/ros2.yml`) fails when the zenoh ones disagree.

| What | Value | Where |
|---|---|---|
| zenoh router image | `eclipse/zenoh:1.9.0` | `compute/docker-compose.yml`, `local/base.yml` |
| zenoh Python client | `eclipse-zenoh==1.9.0` | `compute/images/ros2/Dockerfile` |
| zenoh in the Elixir bridge | `zenohex 0.9.0` (pins zenoh 1.9.0) | `bridges/ros_bridge/mix.exs` |
| ROS 2 distribution | `ros:lyrical-ros-base` | `compute/images/ros2/`, `compute/images/nav2/`, `local/images/sim/` |
| Gazebo | Jetty, via `ros-lyrical-ros-gz` | `local/images/sim/Dockerfile` |
| Wi-Fi firmware | linux-firmware `20260810`, checksummed | `compute/images/wifi-firmware/Dockerfile` |

## Notes

- `network_mode: host` is used on both sides so Zenoh's local
  discovery and any `ros2 daemon` tooling behave the same as a
  bare-metal install.
- The Nerves bridges' `ZENOH_ENDPOINT_IP` is **baked in at firmware
  build time** (`vehicles/<name>/.env.exs`), so the compute node needs
  a static address and repointing it means rebuilding and re-uploading
  every bridge firmware.
- `local/workspace/` is bind-mounted into the `ros2` service at
  `/workspace` for ROS packages you are iterating on (gitignored). A
  node that graduates to running on the car gets an image under
  `compute/images/` instead — the vehicle has no bind mounts.
- The vehicle compose file is written against the balena supervisor's
  Compose subset: no anchors, no `extends:`, no `${VAR:-}`, no
  `profiles:`, no `container_name`, no bind mounts. Its header lists
  each omission; [`docs/ros_compute_node.md`](../docs/ros_compute_node.md)
  explains what that costs.
