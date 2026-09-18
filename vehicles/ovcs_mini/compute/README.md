# compute — the OVCS Mini's compute node

Everything that runs on the Mini's compute node, as one balena release.
This directory is the balena **source root**: `balena push` is run from
here, reads `docker-compose.yml` (that exact name, at this exact place)
and tars up the rest as build context. The machine is a Raspberry Pi 5,
see [`docs/ros_compute_node.md`](../../../docs/ros_compute_node.md).

```
compute/
├── docker-compose.yml    the stack: wifi_firmware, wifi_ap_fix, bridge_nat_fix, zenohd, foxglove_bridge, nav2
├── .dockerignore         keeps host/ and this file out of the pushed tarball
├── nav2/
│   ├── Dockerfile        FROM the framework's Nav2 image, COPY config
│   └── config/           nav2.yaml and the Ackermann behaviour trees — this vehicle's geometry and limits
└── host/                 NetworkManager keyfiles for balenaOS itself — installed by hand, once
```

## Framework and vehicle

The framework — [`compose/`](../../../compose/README.md) — owns the
images: the shared ROS 2 image, Nav2's servers and launch file, the
Wi-Fi firmware, access point and bridge NAT fixes. CI publishes them
to `ghcr.io/open-vehicle-control-system/ovcs/<name>` on every merge to
`main`, and this compose file names those tags. balena pulls them; it
builds nothing of the framework.

This directory owns what is the Mini's: which services run, and the
Nav2 parameters. `nav2/Dockerfile` is two lines — the framework image
plus `COPY config` — because balenaOS has no bind mounts and the
configuration has to ship inside an image.

`latest` follows the framework's `main`. A `balena push` therefore
picks up whatever the framework has merged since the last one. To hold
the car at a known framework, pin the services to a `sha-<short>` tag
(the workflow publishes one per merge) and bump it deliberately.

## Deploying

```sh
cd vehicles/ovcs_mini/compute
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

The 3.4.3 bridge still declares `use_compression` and `send_buffer_limit`,
but its SDK-backed WebSocket initialization does not use them. Do not
rely on those parameters for compression or a byte-based queue limit.
See the [versioned bridge source](https://github.com/foxglove/foxglove-sdk/blob/ros-v3.4.3/ros/src/foxglove_bridge/src/ros2_foxglove_bridge.cpp).

The relay lives in the framework's shared image; its integration tests
run from the repo root in an environment with `websockets==17.0.1`:

```sh
python3 -m unittest discover -s compose/images/ros2/docker/tests -v
```

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
`compose/local/base.yml --profile standalone` — both start a router on
port 7447. And note what this rehearsal is not: Nav2 here runs
always-on against the wall clock with the router at `127.0.0.1`, the
car's configuration. To *work* with the same images on a workstation
use `compose/local/base.yml` (`--profile standalone --profile nav2`),
or `compose/local/simulation.yml --profile nav2` against Gazebo — the
same images, plus the profiles, `.env` and bind mounts that balena
forbids. Both read `OVCS_VEHICLE=ovcs_mini` from `compose/local/.env`
to find this directory.

The first push after a change to this directory's layout should be a
local-mode push to one device: the supervisor's compose parser is a
subset of Compose (see below) and only a real push exercises it.

## What may and may not be written here

The balena supervisor's parser is based on Compose 2.4, so
`docker-compose.yml` stays **literal**: no YAML anchors, no `extends:`,
no `${VAR:-default}`, no `profiles:`, no `container_name`, no
`device_cgroup_rules`, no host bind mounts, and a service either pulls
a published `image:` or carries its own `build:` — balena tags per
service and cannot reference a sibling's tag. The Zenoh environment the
local stacks share through `compose/local/common.yml` is therefore
spelled out in each service here; a change to one is a change to the
other.

Per-directory detail lives in the file headers — the compose file and
`nav2/Dockerfile` say what they do and why the unobvious choices were
made. [`host/README.md`](./host/README.md) covers the network
configuration that is applied to the OS rather than pushed.
