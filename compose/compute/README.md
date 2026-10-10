# compute — the vehicle's compute node

Everything that runs on the vehicle's compute node, as one balena
release. This directory, plus your vehicle's files staged into
`vehicle/`, is the balena **source root**: `balena push` reads
`docker-compose.yml` (that exact name, at the root) and tars up the
rest as build context. What the machine is (see
[`docs/ros2_compute_node.md`](../../docs/ros2_compute_node.md)) does not
show in the layout, and neither does what the services are written in:
`wifi_firmware` is not ROS, and the next onboard service need not be
either.

```
compute/
├── docker-compose.yml    the stack: wifi_firmware, bridge_nat_fix, zenohd, foxglove_bridge, nav2
├── .dockerignore         keeps host/ and this file out of the pushed tarball
├── images/
│   ├── ros2/             the shared ROS 2 image: entrypoint, Zenoh template, launchers
│   ├── nav2/             the Nav2 image and its launch file; it COPYs ../ros2 and ../../vehicle/nav2
│   ├── wifi-firmware/    AX210 firmware staged into balenaOS's extra-firmware volume
│   └── bridge-nat-fix/   keeps the host's NAT off frames bridged between eth0 and the AP
├── vehicle/nav2/         empty here; `ovcs compute stage` copies vehicles/<vehicle>/nav2 into it
└── host/                 NetworkManager keyfiles for balenaOS itself — installed by hand, once
```

## Deploying

From the repo root:

```sh
./ovcs compute push <vehicle> <fleet>            # build on balena's builders, OTA to the fleet
./ovcs compute push <vehicle> <device>.local     # local mode: build on the device, no cloud
```

The command stages this directory and `vehicles/<vehicle>/nav2/` into a
temporary source root and runs `balena push` from it; arguments after
`--` go to `balena push` (`-- --nolive`). A `balena push` run from this
directory directly ships a Nav2 image with no parameters.

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

### Rehearsing on a workstation

The file is plain Compose (a subset of it), so it also runs on any
Docker host, which is the closest check of the file itself short of a
`balena push`. Run it from a staged tree, which carries the vehicle's
Nav2 parameters:

```sh
./ovcs compute stage <vehicle> --out /tmp/compute
cd /tmp/compute
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
never list `images/` or `vehicle/`: the local stacks build the Nav2 image
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
