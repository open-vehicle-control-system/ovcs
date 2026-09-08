# compute — the vehicle's compute node

Everything that runs on the vehicle's compute node, as one balena
release. This directory is the balena **source root**: `balena push`
is run from here, reads `docker-compose.yml` (that exact name, at this
exact place) and tars up the rest as build context. What the machine
is — today a Raspberry Pi 5 on the OVCS Mini, see
[`docs/ros_compute_node.md`](../../docs/ros_compute_node.md) — does not
show in the layout, and neither does what the services are written in:
`wifi_firmware` is not ROS, and the next onboard service need not be
either.

```
compute/
├── docker-compose.yml    the stack: wifi_firmware, zenohd, foxglove_bridge, nav2
├── .dockerignore         keeps host/ and this file out of the pushed tarball
├── images/
│   ├── ros2/             the shared ROS 2 image: entrypoint, Zenoh template, launchers
│   ├── nav2/             the Nav2 image (Dockerfile only; it COPYs ../ros2 and ../../nav2)
│   └── wifi-firmware/    AX210 firmware staged into balenaOS's extra-firmware volume
├── nav2/
│   ├── launch/           baked into images/nav2 here, bind-mounted by ../local/simulation.yml
│   └── config/           nav2.yaml and the Ackermann behaviour trees
└── host/                 NetworkManager keyfiles for balenaOS itself — installed by hand, once
```

## Deploying

```sh
cd compose/compute
balena push ovcs-mini-ros          # build on balena's builders, OTA to the fleet
balena push <device>.local         # local mode: build on the device, no cloud
```

Plain `docker compose up -d` also works here for a bare-metal rehearsal
on any aarch64 box. Runtime configuration is balena fleet/device
variables, not a `.env` file.

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
