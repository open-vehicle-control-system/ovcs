# ROS Compute Node

The OVCS Mini's ROS 2 box: a dedicated Raspberry Pi running the Zenoh
router and the on-vehicle ROS nodes on an immutable, container-based
OS. It is the one machine on the vehicle that is *not* Nerves.

## Why it exists

Every other Pi on the Mini runs Nerves — an immutable, A/B-updated
image with the Elixir application baked in. Nerves cannot host the ROS
2 stack: there is no ROS 2 in Buildroot and no container runtime in a
Nerves image. The pieces that need a full Linux userland (`zenohd`,
`foxglove_bridge`, any rclcpp/rclpy node) therefore need their own
machine.

The design goal is that this machine is immutable *in the same sense*
the Nerves ones are: nothing is configured by hand over SSH, the OS
updates atomically with rollback, and the state that matters lives in
the repo, not on the SD card.

## Topology

```
                 ┌──────────────────────────────────────────┐
                 │ ROS compute Pi — balenaOS                │
  Nerves ────────┤   zenohd            (router, :7447)      ├──────── base station
  bridges  tcp   │   foxglove_bridge   (:8765)              │  tcp    (docker compose,
  (clients)      │   autonomy / perception nodes            │          Foxglove Studio)
                 └──────────────────────────────────────────┘
```

The vehicle is the router. Everything else — the Nerves bridges, the
on-vehicle nodes, the operator's laptop — is a Zenoh **client**, so
the fabric survives the base station driving away. Compose files for
both sides live in [`ros2/`](../ros2/README.md).

## Hardware

| Item | Choice | Why |
|---|---|---|
| Board | Raspberry Pi 5, 8 GB | ROS 2 Jazzy + Foxglove + perception nodes want the headroom |
| Storage | NVMe (HAT) or USB SSD | ROS images are multi-GB and container writes destroy SD cards |
| Clock | Pi 5 RTC connector + battery, plus NTP | see [Clock](#clock) |
| Network | wired or Wi-Fi, **static address** | the bridges' router IP is baked into firmware, see [Wiring it into OVCS](#wiring-it-into-ovcs) |

This is a **new Pi**, not a repurposed one:

- The **VMS Pi 4** is vehicle control. Coupling it to the ROS fabric
  puts a container runtime in the safety path.
- The **`ros_perception` Pi 5** already runs the stereo/Hailo pipeline
  as Nerves + Elixir (`vehicles/ovcs_mini/lib/ovcs_mini.ex`,
  `bridge_firmwares/0`). It stays as it is; it joins the fabric as a
  client like the other bridges.

## Operating system

**balenaOS.** Read-only rootfs, A/B OTA with delta updates, containers
as the only unit of deployment, and first-class Raspberry Pi 5 support.
Critically, it takes a `docker-compose.yml` as the deployment unit, so
the stack we already run in development is the stack that ships.

The cost is a control plane: balenaCloud (free tier covers a handful of
devices) or self-hosted openBalena, which no other part of this repo
depends on. That is the trade-off to accept or reject before going
further.

Alternatives weighed and not chosen:

- **NixOS** — the best fit for this repo's ethos: the vehicle's OS
  becomes a file next to `ros2/`, generations give atomic rollback,
  `nixos-rebuild --target-host` is the update path, and there is no
  vendor. Friction: Pi 5 needs the vendor-kernel route
  (`raspberry-pi-nix` / `nixos-hardware`), and it is a new toolchain
  for the team. The realistic runner-up.
- **Fedora IoT** — rpm-ostree + podman quadlets, the standard immutable
  Linux answer. Fedora supports a board once mainline u-boot and the
  kernel do, and the Pi 5 has historically lagged there; boot a live
  image on the actual board before committing.
- **Ubuntu Core** — snap confinement makes `/dev/input`, `/dev/video*`
  and X forwarding painful for exactly the services we want.
- **Raspberry Pi OS + overlayfs** — zero friction, but a read-only root
  without atomic updates or rollback is the half of "immutable" that
  doesn't matter on a vehicle.

## Deploying

The CLI is pinned in `mise.toml` (`balena = "25"`), so `mise install` at
the repo root is all the setup there is — the standalone build bundles
its own Node and ignores the repo's `node` pin.

```sh
balena login
cd ros2/vehicule
balena push <fleet>            # build on balena's builders, OTA to the fleet
balena push <device>.local     # local mode: build on the device, no cloud
```

`ros2/vehicule/` is the balena **source root**. That is not cosmetic:
`balena push` only reads a file literally named `docker-compose.yml` at
the root of the pushed directory, and every `build:` context must sit
inside that directory. This is why the shared image moved to
`ros2/vehicule/image/` and the base station reaches across to it, and
not the other way round.

Runtime configuration is balena **fleet/device variables**, not a
`.env` file. Whether such a variable *overrides* a value written
literally in compose `environment:` is not something we have checked,
so the vehicle compose file simply leaves overridable settings unset
(`FOXGLOVE_BRIDGE_PORT`, defaulted by the launcher script) and only
pins what must always be true (`ZENOH_ENDPOINT_IP`, required by the
entrypoint).

### What the compose subset costs you

The balena supervisor implements a subset of Compose (see the
[supported fields reference](https://docs.balena.io/reference/supervisor/docker-compose/)).
`ros2/vehicule/docker-compose.yml` is written to stay inside it, and
the differences from `ros2/base/docker-compose.yml` are all forced:

| Not usable on balena | Consequence |
|---|---|
| host bind mounts | no `./workspace` on the vehicle — nodes ship **in the image** |
| `container_name` | the supervisor names containers |
| `profiles:` | one file, one always-on set of services |
| `device_cgroup_rules` | hot-plug device tricks need `privileged` / balena labels instead |
| shared image tags across services | every custom-image service carries its own `build:` |
| BuildKit | no `COPY --chmod=`, no heredocs, no `RUN --mount` — balenaEngine builds with the classic engine |

YAML anchors and `${VAR:-default}` interpolation are avoided too — not
because they are known to fail, but because they are unverified against
the balena parser and the launcher scripts already default everything.

## Wiring it into OVCS

1. Give the ROS Pi a **static address** (DHCP reservation or a
   NetworkManager profile — see balena's networking docs for the
   file location and syntax on balenaOS).
2. Set `ZENOH_ENDPOINT_IP` to that address in
   `vehicles/ovcs_mini/.env.exs`.
3. **Rebuild and re-upload every firmware that hosts `RosBridge`** —
   on the Mini that is `bridge-ros` and `bridge-ros_perception`.
   (`bridge-radio_control` gets the value stamped too, but never
   reads it.) The endpoint is
   baked into application config at build time
   (`bridges/firmware/config/target.exs`), not read at boot: `.env.exs`
   only `System.put_env`s on the build host, so the device-side
   `System.get_env` returns nil. Two failure modes follow — a firmware
   that isn't rebuilt keeps peering with the *old* address, and one
   built without `ZENOH_ENDPOINT_IP` set falls back to `127.0.0.1`,
   where no router is listening.
4. Point the base station at it: `ZENOH_ENDPOINT_IP` in
   `ros2/base/.env`, and Foxglove Studio at `ws://<pi-ip>:8765`.

Worth deciding early whether to keep step 3. Making the endpoint
runtime-resolvable (or resolving a stable mDNS name) would turn a
three-firmware rebuild into a reboot.

Version coupling to keep in mind: `zenohex 0.9.0`, which `ros_bridge`
depends on, pins zenoh **1.9.0** — the same version as the
`eclipse/zenoh:1.9.0` router image. Bump them together.

## Clock

Every publisher on the fabric stamps its samples with a nanosecond
source timestamp (`Ros2.RmwZenoh.attachment/3` on the Elixir side), and
consumers act on those: the stereo pipeline pairs left/right frames
inside a time window (`APPROXIMATE_SYNC`, default 50 ms) and Foxglove
orders everything it displays by them. So the clocks have to agree
*across machines*, not just be monotonic on each.

The Nerves bridges get this from `nerves_time`, which also floors the
clock at the firmware's build time so a network-less boot is merely
stale rather than nonsense. This Pi needs the equivalent: NTP once the
network is up, and the Pi 5's RTC battery fitted so the window before
that isn't spent publishing timestamps from an arbitrary epoch.

## Two update paths

The vehicle now has two:

- Nerves bridges — `./ovcs upload <vehicle> <firmware>` (see
  [Running on Hardware](./running_hardware.md)).
- ROS compute node — `balena push`, or an OTA from the fleet.

Whether the `ovcs` CLI should grow a subcommand that wraps the second
one is open.

## Open questions

- balenaCloud vs self-hosted openBalena vs falling back to NixOS.
- NVMe boot on balenaOS for the Pi 5 — confirm against balena's Pi 5
  documentation before ordering the HAT.
- Whether `joy` stays on the base station (it does today, and the
  round trip pad → ROS → Zenoh → `RosBridge.Consumers.Joy` → CAN is
  the price of keeping the controller with the operator). If a pad
  ever rides on the car, an Elixir `input_event` reader driving CAN
  directly deletes a container.
- Baking `vehicles/ovcs_mini/priv/calibration/*` — currently produced
  on the base station and committed; unchanged by this split.

Next: [Running on Hardware](./running_hardware.md)
