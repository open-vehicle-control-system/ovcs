# compute — the vehicle's compute node

Everything that runs on the vehicle's compute node, as one balena
release. This directory is the balena **source root**: `balena push`
is run from here, reads `docker-compose.yml` (that exact name, at this
exact place) and tars up the rest as build context. What the machine
is — today a Raspberry Pi 5 on the OVCS Mini, see
[`docs/ros2_compute_node.md`](../../docs/ros2_compute_node.md) — does not
show in the layout, and neither does what the services are written in:
`wifi_firmware` is not ROS, and the next onboard service need not be
either.

```
compute/
├── docker-compose.yml    the stack: wifi_firmware, bridge_nat_fix, zenohd, foxglove_bridge, nav2, rtabmap, explore
├── .dockerignore         keeps host/ and this file out of the pushed tarball
├── images/
│   ├── ros2/             the shared ROS 2 image: entrypoint, Zenoh template, launchers
│   ├── nav2/             the Nav2 image (Dockerfile only; it COPYs ../ros2 and ../../nav2)
│   ├── rtabmap/          the RTAB-Map image (Dockerfile only; it COPYs ../ros2 and ../../rtabmap)
│   ├── explore/          camera-viewpoint supervisor (COPYs ../ros2, ../../explore)
│   ├── wifi-firmware/    AX210 firmware staged into balenaOS's extra-firmware volume
│   └── bridge-nat-fix/   keeps the host's NAT off frames bridged between eth0 and the AP
├── nav2/
│   ├── launch/           baked into images/nav2 here, bind-mounted by ../local/simulation.yml
│   └── config/           nav2.yaml and the Ackermann behaviour trees
├── rtabmap/              launch file and parameters baked into images/rtabmap
├── explore/              viewpoint selection, motion guard, action handling, launch and tests
└── host/                 NetworkManager keyfiles for balenaOS itself — installed by hand, once
```

## Deploying

```sh
cd compose/compute
balena push ovcs-mini-ros          # build on balena's builders, OTA to the fleet
balena push <device>.local         # local mode: build on the device, no cloud
```

Runtime configuration is balena fleet/device variables, not a `.env`
file.

### Foxglove on slower Wi-Fi

The public endpoint remains `ws://<compute-node-ip>:8765`. A local relay
negotiates WebSocket `permessage-deflate` with compatible clients and forwards
the original Foxglove text and binary messages in both directions using the
bridge's `foxglove.sdk.v1` subprotocol. Compression
is lossless: topics, frame rates, image resolution and layouts are unchanged.
Clients without compression support can still connect, without the bandwidth
savings. The relay logs the negotiated extension for each connection.

The ROS bridge listens on loopback port 8766, configurable with
`FOXGLOVE_BRIDGE_INTERNAL_PORT`; the public port uses `FOXGLOVE_BRIDGE_PORT`.
Both processes run in the bridge container and a child failure exits the
service so the supervisor can restart it. The relay uses compression level 1,
a receive high-water mark of one frame and a 32 KiB write high-water mark.
These limits propagate slow-client backpressure to the bridge rather than
adding an unbounded application queue. Kernel socket buffers still apply.

The bridge limits each client's outgoing queue to 32 messages with
`FOXGLOVE_MESSAGE_BACKLOG_SIZE` (Foxglove Bridge 3.4.1 or later). Set this
fleet/device variable to override the limit; it is read at startup.
When the queue fills, the SDK drops the oldest data messages. This keeps
less stale data queued without changing the layout or source topics.
The limit is in messages, not bytes, and does not bound TCP buffers or
reduce the source bandwidth. A full control-message queue disconnects
the client, so check reconnections when reducing the limit further.

A third process, `foxglove_watchdog`, exits when the bridge leaves more
than 1 MB unread on its Zenoh connection for 10 s. A client that stops
draining its session fills the router's queue towards it, and the router
then stalls graph discovery for every node, Nav2 included; the restart
opens a fresh session.

The 3.4.3 bridge still declares `use_compression` and `send_buffer_limit`,
but its SDK-backed WebSocket initialization does not use them. Do not
rely on those parameters for compression or a byte-based queue limit.
See the [versioned bridge source](https://github.com/foxglove/foxglove-sdk/blob/ros-v3.4.3/ros/src/foxglove_bridge/src/ros2_foxglove_bridge.cpp).

Run the relay integration tests in an environment with `websockets==17.0.1`:

```sh
python3 -m unittest discover -s images/ros2/docker/tests -v
```

### Mapping and exploring

`rtabmap` publishes `/rtabmap/map` and `map -> odom` from the stereo depth
image and `/odom`. Its database persists across restarts. A new mapping
session requires an explicit `delete_db_on_start:=true` launch argument;
a failed database load does not silently erase the map. Every mapper
restart changes `/rtabmap/session` and stops any active exploration.

The `explore` container idles until launched. With the OVCS Mini reference
vehicle in `:ros` / `:autonomous`, start it with:

```sh
balena-engine exec -d "$(balena-engine ps -qf name=explore)" bash -lc \
  'source /opt/ros/lyrical/setup.bash && exec ros2 launch /opt/ovcs/launch/explore.launch.py'
```

`forward_explore` scores known-free viewpoints facing map frontiers using
the matched stereo field of view. It preflights candidate routes with `ComputePathToPose`, ranks their actual
length against expected gain, then sends `NavigateToPose` goals. Smac
Hybrid checks forward-only routes with a 0.70 m minimum turning radius, and
Regulated Pure Pursuit follows them. The rear axle is the control reference.
The camera origin is 0.204 m ahead and 0.045 m left of it. Every planned
footprint must be in mapped free space and inside the mission perimeter.
RPP follows forward routes and has a separate controller for short retreats.
MPPI parameters are retained for explicit offline comparisons. There are no
spin recoveries or obstacle-clearing recoveries. A viewpoint succeeds only with both its position and heading
reached. Repeated failures or no map growth end the mission.

If navigation fails or no forward route remains, the supervisor can retrace
the last 0.20 m actually driven, at 0.10 m/s. It waits for the old action to
terminate and for standstill, then submits that measured route to `FollowPath`.
It attempts one retreat until a forward viewpoint produces new map coverage,
with at most three retreats per mission. It replans after retreating and
temporarily excludes failed goals. A failed retreat ends the mission.
A short retreat may create turning room; it cannot escape every dead end.

The velocity path is:

```text
Nav2 -> /cmd_vel_nav_raw -> velocity_smoother -> /cmd_vel_nav_smoothed
     -> motion_guard -> /cmd_vel_nav -> ROS bridge -> CAN -> VMS
```

The guard runs independently of the explorer. Motion requires an accepted
action, a checked plan and a lease renewed within 0.5 s. It checks source
and receipt timestamps for odometry, point clouds, costmaps, maps and mapper
heartbeats, plus TF age. All boards must use synchronized clocks; source
timestamps more than 100 ms in the future are rejected. It tests the full footprint through a stopping
envelope against the map, local costmap and perimeter. Reverse requires a
separate retreat authorization and recently traversed space (15 s). The guard
limits it to 0.10 m/s and cuts commands after 0.25 m measured travel or 6 s
per attempt; heartbeats cannot renew those limits. The overall reverse budget
is 1 m per mission.
All motion is limited to 0.25 m/s and 600 s. The RPP approach floor is
0.10 m/s, above the smoother's 0.08 m/s deadband. Velocity limits preserve
curvature. The bridge also rejects delayed or replayed stamped commands.

A new map cannot certify the stereo camera's blind area under and behind
the vehicle. Start from a mapped, clear staging area; the supervisor waits
until the complete footprint is known free. Unknown space never becomes
free merely because a local obstacle expired. Depth and cloud share the
same spatially filtered disparity; no camera-frame temporal persistence
filter discards newly observed obstacles. Both mapping and local obstacle
marking use a 5 cm ground threshold.

Publish `false` on `/forward_explore/resume` to pause. The lease is revoked
immediately and cancellation is retained even if Nav2 accepts the goal
later. Publish `true` after cancellation completes to begin a new mission
at the current pose. A completed or faulted process must be launched again.
Stopping or killing the explorer expires its lease. The radio's control
level switch remains the physical authority over ROS commands.

Use `dry_run:=true` on the launch command to inspect candidates without
sending goals. Viewpoints appear on `/forward_explore/candidates`; decisions
appear on `/rosout`, and `/motion_guard/status` reports the stop reason,
fault and measured reverse distance. The tunable defaults live in
`explore/config/forward_explore.yaml` and `nav2/config/nav2.yaml`.

Offline checks, from the repository root:

```sh
python3 -m unittest discover -s compose/compute/explore/forward_explore/tests -v
compose/local/scripts/verify_exploration.sh
```

The first command needs NumPy; ROS-specific tests run inside the Nav2
image in CI. The second builds that image and runs real Nav2 servers,
the explorer and guard in network-isolated containers against a synthetic
map/cloud source and an Ackermann plant with steering lag and a speed
deadband. It checks mapped motion, arrival, perimeter, reverse budget and
stopping after sensor, TF or explorer loss, including during retreat. The
dead-end case must complete one short retreat without repeating it. It leaves JSON results and
logs in the printed directory. It does not exercise camera matching,
RTAB-Map loop closures, CAN timing or physical motor braking.

The stopping envelope assumes at least 0.3 m/s² deceleration and 0.6 s
reaction time. Those values and the 5 cm ground threshold need measured
vehicle validation. Zero ROS velocity is not evidence of physical standstill;
the Mini's VESC zero-duty behavior, stopping distance, camera calibration,
floor reflections and thin obstacles must be checked before unattended use.
The forward camera cannot detect a new obstacle entering behind the vehicle;
recent traversal does not guarantee current rear clearance.

### Rehearsing on a workstation

The file is plain Compose (a subset of it), so it also runs on any
Docker host, which is the closest check of the file itself short of a
`balena push`:

```sh
docker compose up -d zenohd foxglove_bridge nav2
```

Name the services: `wifi_firmware` copies its blobs into
`/extra-firmware`, a volume only balenaOS mounts (through the
`io.balena.features.extra-firmware` label), so on a workstation the
copy fails and the container restarts forever, and `bridge_nat_fix`
would edit the workstation's nat table. Do not run this beside
`../local/base.yml --profile standalone` — both start a router on
port 7447. And note what this rehearsal is not: Nav2 here runs
always-on against the wall clock with the router at `127.0.0.1`, the
car's configuration. To *work* with the same images on a workstation
use `../local/base.yml` (`--profile standalone --profile nav2`), or
`../local/simulation.yml --profile nav2` against Gazebo — same
Dockerfiles, same tags, plus the profiles, `.env` and bind mounts that
balena forbids.

The first push after a change to this directory's layout should be a
local-mode push to one device: the supervisor's compose parser is a
subset of Compose (see below) and only a real push exercises it.

## What may and may not be written here

The balena supervisor's parser is based on Compose 2.4, so
`docker-compose.yml` stays **literal**: no YAML anchors, no `extends:`,
no `${VAR:-default}`, no `profiles:`, no `container_name`, no
`device_cgroup_rules`, no host bind mounts, and one `build:` per
service because balena tags per service and cannot reference a sibling's
tag. The Zenoh environment the local stacks share through
`../local/common.yml` is therefore spelled out in each service here; a
change to one is a change to the other.

`.dockerignore` lists what never needs to reach the builders. It must
never list `images/` or `nav2/`: the local stacks build the Nav2 image
with this directory as context (`context: ../compute`), and a single
root `.dockerignore` applies to every build that uses it.

## Why the images live here and not in `../local`

balena requires every `build:` context inside the pushed directory and
its builders start from public bases only — they cannot inherit from an
`ovcs/*` tag that exists on a workstation. So every image the car runs
is defined here, and the local stacks reach across to build the same
Dockerfiles under the same tags (`ovcs/ros2:lyrical`,
`ovcs/nav2:lyrical`). The direction is the point: a workstation runs
what the car runs, never a copy of it.

Per-directory detail lives in the file headers — each Dockerfile and
the compose file say what they do and why the unobvious choices were
made. [`host/README.md`](./host/README.md) covers the network
configuration that is applied to the OS rather than pushed.
