# Container stacks

The framework's side of everything in this project that runs in a
container. Two questions decide where a file lives: **is it the
framework's or a vehicle's**, and **is it pushed to a vehicle or does
it never leave a workstation?**

```
compose/                            THE FRAMEWORK
├── images/                         every image a vehicle's compute node runs — published to GHCR by CI
│   ├── ros2/                       the shared ROS 2 image: entrypoint, Zenoh template, launchers
│   ├── nav2/                       Nav2's servers and generic launch file — no vehicle parameters
│   ├── wifi-firmware/              AX210 firmware staged into balenaOS's extra-firmware volume
│   ├── wifi-ap-fix/                keeps the 5 GHz access point on its channel
│   └── bridge-nat-fix/             keeps the host's NAT off frames bridged between eth0 and the AP
└── local/                          NEVER PUSHED — the operator's machine and the simulation workstation
    ├── common.yml                  the shared service definitions the two stacks `extends:`
    ├── base.yml                    operator laptop: ros2 shell, joy, calibrator, standalone router, nav2 profile
    ├── simulation.yml              Gazebo: sim, teleop, gz-gui, nav2 against the simulator
    ├── images/sim/                 the Gazebo image — the only one that never goes near a car
    ├── simulation/                 worlds, macros, launch files, gamepad mapping, test scripts
    ├── scripts/                    the verifiers behind `mise run verify-*`, and calibrate.sh
    └── calibration_output/         where the stereo calibrator drops its tarball

vehicles/<name>/compute/            THE VEHICLE — pushed to balena, one deployable unit
├── docker-compose.yml              which services run, naming the framework's GHCR images
├── nav2/                           FROM the framework's Nav2 image, COPY this vehicle's config/
└── host/                           balenaOS network config (copied to the device once, never pushed)
```

The framework owns the images and the tooling; a vehicle owns which
services it runs and the parameters that describe it — Nav2's
wheelbase, turning radius and speed limits are the vehicle's, not the
planner's. What the two halves share is the Zenoh fabric: ROS 2 nodes
use `rmw_zenoh_cpp`, the Elixir `ros_bridge` speaks the same wire
format natively, and everything is a client of one router — no DDS, no
multicast, just TCP peerings to `zenohd`.

## Who runs what

| Service | Where | Why |
|---|---|---|
| `zenohd` | vehicle | the fabric must outlive the operator's laptop |
| `foxglove_bridge` | vehicle | Studio attaches over the LAN to `ws://<compute-node-ip>:8765` |
| `nav2` | vehicle | the planner survives the base station leaving, like the router |
| `wifi_firmware` | vehicle | AX210 blobs for the host kernel — not ROS at all |
| `wifi_ap_fix` | vehicle | the access point's channel-149 centre frequency — not ROS either |
| `bridge_nat_fix` | vehicle | one nat rule so mDNS crosses the vehicle bridge |
| `ros2` (tooling shell) | local/base | interactive, `docker compose exec` |
| `joy` | local/base | the game controller is with the operator, not the car |
| `calibrator` | local/base | one-shot X11 GUI |
| `sim`, `teleop`, `gz-gui` | local/simulation | Gazebo and its operator-side extras |

`local/base.yml` also carries `standalone` copies of `zenohd` and
`foxglove_bridge` behind a compose profile, and the vehicle's Nav2
behind another, for developing with no vehicle on the LAN. Two routers
on one LAN is how you end up debugging two fabrics — with a vehicle
present, leave those profiles off.

## Profiles

A service sits behind a profile for one of two mechanical reasons: it
**stands in for something the vehicle provides**, so it must not run
while a vehicle is on the LAN; or it has a **host dependency that would
make a plain `up -d` fail**. Nothing is behind a profile for tidiness.

| Stack | Profile | Adds | Reason |
|---|---|---|---|
| `base.yml` | *(none)* | `ros2`, `joy` | what an operator always wants with a vehicle present |
| `base.yml` | `standalone` | `zenohd`, `foxglove_bridge` | stands in for the vehicle; two routers on one LAN is two fabrics |
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

## Images: built once, run everywhere

balena requires every `build:` context inside the pushed directory and
its builders start from public bases only. Rather than copy the
framework's Dockerfiles into every vehicle, CI
(`.github/workflows/ros2.yml`) builds `images/*` for amd64 and arm64 on
every merge to `main` and publishes them to GHCR. A vehicle's compose
file names the tag and balena pulls it; the local stacks build the
same Dockerfiles under the same name, so `docker compose pull` and
`docker compose build` are two ways to the same image. A workstation
runs what the car runs, never a copy of it.

| Image | Dockerfile | Published as | Used by |
|---|---|---|---|
| shared ROS 2 | `images/ros2/` | `ghcr.io/open-vehicle-control-system/ovcs/ros2` | the vehicle's `foxglove_bridge`; `local/base.yml` (`ros2`, `joy`, `calibrator`, `foxglove_bridge`) |
| Nav2 | `images/nav2/` (context `images/`) | `ghcr.io/open-vehicle-control-system/ovcs/nav2` | the base of every vehicle's `compute/nav2/Dockerfile` |
| Wi-Fi firmware | `images/wifi-firmware/` | `…/ovcs/wifi-firmware` | vehicle only |
| AP fix | `images/wifi-ap-fix/` | `…/ovcs/wifi-ap-fix` | vehicle only |
| bridge NAT fix | `images/bridge-nat-fix/` | `…/ovcs/bridge-nat-fix` | vehicle only |
| Gazebo | `local/images/sim/` (context `compose/`) | `ovcs/sim:jetty`, local only | `local/simulation.yml` only |

Two tags per image: `latest` follows `main`, and `sha-<short>` is the
immutable name for a vehicle that must hold a known framework. Pull
requests build every image for both architectures without publishing,
so an arm64 build failure shows up before a deploy.

Nav2 is the one image with a vehicle half. The framework image carries
the servers and a launch file that reads `/opt/ovcs/config/nav2.yaml`
and ships no such file; `vehicles/<name>/compute/nav2/Dockerfile` is
`FROM` that image plus `COPY config /opt/ovcs/config`. Both local
stacks build the vehicle's image — `OVCS_VEHICLE` in `local/.env`
names the vehicle directory — and the simulator bind-mounts the same
`config/` over it so a parameter edit is tried without a rebuild. The
one difference between a simulated and an onboard run is the clock, and
it is a visible launch argument (`use_sim_time:=true`).

## Starting each stack

Every local command is run from `compose/local/` and names its file:
the stacks are `base.yml` and `simulation.yml` rather than a
`docker-compose.yml` per directory, so `-f` is always spelled out. Each
carries its own project `name:` so the two never collide.

**Operator machine, with a vehicle on the LAN:**

```sh
cd compose/local
cp .env.example .env               # ZENOH_ENDPOINT_IP → the vehicle's compute node, OVCS_VEHICLE → its directory
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

**Vehicle:** see the vehicle's own `compute/README.md` —
[`vehicles/ovcs_mini/compute/`](../vehicles/ovcs_mini/compute/README.md)
for the Mini — and `balena push` from there.

## Adding a vehicle's compute node

1. `vehicles/<name>/compute/docker-compose.yml`, written against the
   balena supervisor's Compose subset (the Mini's file lists what that
   excludes), naming the GHCR images for the services the vehicle runs.
2. `vehicles/<name>/compute/nav2/Dockerfile` + `config/` if it
   navigates: `FROM …/ovcs/nav2:latest`, `COPY config /opt/ovcs/config`.
3. `vehicles/<name>/compute/host/` if it needs balenaOS network
   configuration.
4. Its compose file in the `compose-config` matrix and its directory in
   the `vehicle-image` matrix of `.github/workflows/ros2.yml`.

A service only that vehicle runs is a `build:` under its `compute/`;
a service a second vehicle would want is a Dockerfile under `images/`
here, added to the `image` matrix so CI publishes it.

## Versions

The pins below have to move together. CI (`pins` job in
`.github/workflows/ros2.yml`) fails when the zenoh ones disagree.

| What | Value | Where |
|---|---|---|
| zenoh router image | `eclipse/zenoh:1.9.0` | `vehicles/*/compute/docker-compose.yml`, `local/base.yml` |
| zenoh Python client | `eclipse-zenoh==1.9.0` | `images/ros2/Dockerfile` |
| zenoh in the Elixir bridge | `zenohex 0.9.0` (pins zenoh 1.9.0) | `bridges/ros_bridge/mix.exs` |
| ROS 2 distribution | `ros:lyrical-ros-base` | `images/ros2/`, `images/nav2/`, `local/images/sim/` |
| Gazebo | Jetty, via `ros-lyrical-ros-gz` | `local/images/sim/Dockerfile` |
| Wi-Fi firmware | linux-firmware `20260810`, checksummed | `images/wifi-firmware/Dockerfile` |

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
  `images/` instead — the vehicle has no bind mounts.
- A vehicle's compose file is written against the balena supervisor's
  Compose subset: no anchors, no `extends:`, no `${VAR:-}`, no
  `profiles:`, no `container_name`, no bind mounts. The Mini's header
  lists each omission; [`docs/ros_compute_node.md`](../docs/ros_compute_node.md)
  explains what that costs.
