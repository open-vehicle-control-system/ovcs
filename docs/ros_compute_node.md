---
title: ROS compute node
description: The non-Nerves Pi that runs the Zenoh router and the on-vehicle ROS nodes on balenaOS, and the vehicle network it owns, with the OVCS Mini reference application as the worked example.
---

Nerves can't host a ROS 2 stack: Buildroot has no ROS 2 and a Nerves image has no container runtime. An application that runs ROS nodes on the vehicle (`zenohd`, `foxglove_bridge`, Nav2, any rclcpp/rclpy node) therefore needs one machine that isn't Nerves: the compute node. This guide uses the OVCS Mini reference application's compute node as the worked example; the design carries over to your application unchanged, only the names and addresses are the Mini's.

The goal is that this machine is immutable in the same sense the Nerves boards are: nothing is configured by hand over SSH, the OS updates atomically with rollback, and the state that matters lives in the repo.

## Topology

```text
                 ┌──────────────────────────────────────────┐
                 │ ROS compute Pi — balenaOS                │
  Nerves ────────┤   zenohd            (router, :7447)      ├──────── base station
  bridges  tcp   │   foxglove_bridge   (:8765)              │  tcp    (docker compose,
  (clients)      │   nav2, perception nodes                 │          Foxglove Studio)
                 └──────────────────────────────────────────┘
```

The vehicle is the router. Everything else (the Nerves bridges, the on-vehicle nodes, the operator's laptop) is a Zenoh **client**, so the fabric survives the base station driving away. Compose files for both sides live in [`compose/`](../compose/README.md): what runs on the vehicle in `compose/compute/`, what stays on a workstation in `compose/local/`.

## Hardware

| Item | Choice | Why |
|---|---|---|
| Board | Raspberry Pi 5, 8 GB | ROS 2 Lyrical, Foxglove and Nav2 want the headroom |
| Storage | NVMe in a USB enclosure | ROS images are multi-GB and container writes wear out SD cards; the PCIe slot holds the Wi-Fi card, so the disk goes on USB. See [Boot media](#boot-media) |
| Clock | Pi 5 RTC battery, plus NTP | see [Clock](#clock) |
| Network | the compute node *is* the vehicle network; every board also joins the site Wi-Fi on its own | the bridges' router address is baked into firmware, so it has to be one you choose. See [Networking](#networking) |
| Wi-Fi | Intel AX210 (M.2 on PCIe) **plus** the onboard radio | the AX210 serves the access point; the onboard radio joins the site Wi-Fi |

Keep it a separate Pi:

- The **VMS** is vehicle control. Coupling it to the ROS fabric puts a container runtime in the safety path.
- A **perception bridge** (on the Mini, the `ros_perception` Pi 5 running stereo depth and Hailo detection in Elixir, see [Perception: object detection](./ros_perception_detection.md)) stays Nerves and joins the fabric as a client like the other bridges.

## Operating system

**balenaOS**: read-only rootfs, A/B OTA with delta updates, containers as the only unit of deployment, first-class Pi 5 support. It takes a `docker-compose.yml` as the deployment unit, so the stack you run in development is the stack that ships. The cost is a control plane: balenaCloud (the free tier covers a handful of devices) or self-hosted openBalena.

Alternatives, and why they lost:

- **NixOS**: the vehicle's OS becomes a file next to `compose/`, generations give atomic rollback, no vendor. The runner-up; the Pi 5 needs the vendor-kernel route (`raspberry-pi-nix` / `nixos-hardware`) and it is a new toolchain.
- **Fedora IoT**: rpm-ostree plus podman quadlets, but Pi 5 support lags mainline u-boot and the kernel.
- **Ubuntu Core**: snap confinement makes `/dev/input`, `/dev/video*` and X forwarding painful for exactly these services.
- **Raspberry Pi OS with overlayfs**: a read-only root without atomic updates or rollback.

### Boot media

The compute node boots from an NVMe SSD in a USB 3 enclosure. The Pi 5 has one PCIe lane and the AX210 is on it, so the disk can't go on an M.2 HAT. The SD card is only for bringing the board up.

The Pi 5 bootloader refuses USB boot on a supply it can't negotiate 5 A from. Without USB-PD it caps the USB ports at 600 mA while looking for a boot device, and an NVMe behind a bridge chip asks for more (an RTL9210B enclosure declares 896 mA). The drive is never seen, the green LED blinks "no boot device", and nothing is logged. A DC-DC converter on a vehicle is never a PD supply, so set it in the bootloader EEPROM, once per board:

1. Flash Raspberry Pi OS Lite to a spare SD card and boot the Pi from it. balenaOS ships no EEPROM tools.
2. `sudo rpi-eeprom-config --edit`, add `PSU_MAX_CURRENT=5000`, keep `BOOT_ORDER=0xf461` (SD, NVMe, USB, retry). Save, `sudo reboot` once so the new bootloader slot is committed, and check that `sudo rpi-eeprom-config` shows the line.
3. Power off, remove the SD card, connect the SSD, power on.

`PSU_MAX_CURRENT` makes the bootloader assume a 5 A supply without asking. That is a promise about the converter: it must deliver 5 A at 5 V, or the symptom moves from "does not boot" to brownouts under load.

Then flash balenaOS:

1. Download the fleet's image from the dashboard (**Add device**, development mode, the site Wi-Fi as the network) and write it to the SSD with Etcher. The device registers in the fleet on first boot under a new name.
2. Enable **local mode** on the new device before the first `balena push`.
3. Delete the previous device from the dashboard: its identity doesn't move with the disk.

The fleet variable `BALENA_HOST_CONFIG_usb_max_current_enable=1` lifts the OS-stage USB budget to 1.6 A once Linux is up. It doesn't reach the bootloader; only the EEPROM setting does.

RTL9210B bridges (firmware 20.01) are known to drop under sustained load on the Pi 5. `uas` resets in `dmesg`, or the disk re-enumerating under container load, mean swapping the enclosure for an ASMedia- or JMicron-based one.

## Deploying

The balena CLI is pinned in `mise.toml` (`balena = "25"`), so `mise install` at the repo root is the whole setup. The standalone build bundles its own Node and ignores the repo's `node` pin.

```sh
balena login
cd compose/compute
balena push <fleet>            # build on balena's builders, OTA to the fleet
balena push <device>.local     # local mode: build on the device, no cloud
```

A local-mode push that is interrupted (by a reboot, say) can leave the built image **untagged** while `local_image_<service>:latest` still resolves to the previous one. The supervisor then runs the old image, and a fix visibly doesn't take although the build succeeded. Check the tag, not the build output:

```sh
balena-engine images --no-trunc --format '{{.Repository}}:{{.Tag}} -> {{.ID}}' \
  | grep <service>
balena-engine inspect $(balena-engine ps -aq --filter name=<service> | head -1) \
  --format '{{json .Config.Cmd}}'
```

Local-mode pushes leave the fleet's target state untouched: nothing reaches other devices until the same code is pushed to the fleet.

`compose/compute/` is the balena **source root**. `balena push` only reads a file literally named `docker-compose.yml` at the root of the pushed directory, and every `build:` context must sit inside it. That is why every image the vehicle runs lives under `compose/compute/images/` and the local stacks reach across to build the same ones, not the other way round. The root's `.dockerignore` keeps `host/` and the README out of the pushed tarball, which is what OTA deltas are computed from.

Runtime configuration is balena **fleet/device variables**, not a `.env` file. Whether such a variable overrides a value written literally in compose `environment:` is unverified, so the vehicle compose file leaves overridable settings unset (`FOXGLOVE_BRIDGE_PORT`, defaulted by the launcher script) and only pins what must always hold (`ZENOH_ENDPOINT_IP`, required by the entrypoint).

### Redeploying the router

`zenohd` is the fabric's router, and the ROS services on the node (`foxglove_bridge`, `nav2`) join it as clients. An `rmw_zenoh_cpp` node declares its publishers and subscriptions to the router it joined. When that router process is replaced (a `balena push` that recreates the `zenohd` container, a crash and restart), the node's TCP session reconnects, but the new router knows nothing of what the node declared. Foxglove then shows the old topic list and no data, `ros2 topic list` in the container hangs, and `zenohd` logs `Unknown interest`. The Nerves boards aren't affected: their sessions are fresh connections and declare themselves again.

The router's REST admin space (`--rest-http-port 127.0.0.1:8000`, loopback only) exposes its `zid`, which changes with every process. With `ZENOH_ROUTER_ADMIN_URL` set in the compose file, the shared entrypoint (`compose/compute/images/ros2/docker/entrypoint.sh`) runs the service under a watch: it waits for the router to answer before launching, then polls the `zid` every 5 s (`ZENOH_ROUTER_WATCH_INTERVAL`) and exits when it changes; `restart: always` brings the service back against the new router. A router that is merely down is left to the sessions' own reconnection.

Waiting before launching also settles the cold-boot order: a Nav2 started before the router times out on its lifecycle manager's first `change_state` call and stays inactive.

### What the compose subset costs you

The balena supervisor implements a [subset of Compose](https://docs.balena.io/reference/supervisor/docker-compose/). `compose/compute/docker-compose.yml` stays inside it, and every difference from `compose/local/*.yml` is forced:

| Not usable on balena | Consequence |
|---|---|
| host bind mounts | no `./workspace` on the vehicle: nodes ship **in the image** |
| `container_name` | the supervisor names containers |
| `profiles:` | one file, one always-on set of services |
| `device_cgroup_rules` | hot-plug device access needs `privileged` or balena labels |
| shared image tags across services | every custom-image service carries its own `build:` |
| BuildKit | no `COPY --chmod=`, no heredocs, no `RUN --mount`: balenaEngine builds with the classic engine |

YAML anchors, `extends:` and `${VAR:-default}` interpolation are avoided too: they are unverified against the balena parser, and the launcher scripts already default everything. The local stacks share their Zenoh environment through `compose/local/common.yml`; the vehicle file spells it out per service.

## Networking

Two networks, each doing one job:

- **The wire is the vehicle.** The compute node runs the access point, the DHCP server and the gateway of `10.42.0.0/24`, so the fabric exists as soon as the vehicle has power, with a router address (`10.42.0.1`) you choose rather than lease. The Nerves boards are cabled to it through the vehicle switch.
- **The site Wi-Fi is for people.** Every board (the compute node through its onboard radio, each Nerves board through its own) also joins the site Wi-Fi as an ordinary client. SSH, `./ovcs connect`, the VMS dashboard, Foxglove and mDNS live there, and so does internet access (balena OTA, the cloud tunnel, NTP).

```text
            site Wi-Fi ── onboard radio of the compute node (uplink, default route)
                       ── wlan0 of each Nerves board (WIFI_NETWORKS)
                              │  NAT
        ┌─────────────────────┴──────────────────────────┐
        │  ovcs0   10.42.0.1/24    NetworkManager bridge │
        │    ipv4.method=shared →                        │
        │      dnsmasq: DHCP .10-.254 + DNS              │
        │      MASQUERADE out via the uplink             │
        └────┬────────────────────────────┬──────────────┘
             │                            │
          eth0                      wlP1p1s0  (AX210 AP, 5 GHz)
     vehicle switch:                a laptop with no site Wi-Fi,
     VMS, bridge-ros,               or one that wants the fabric
     bridge-ros_perception          at full rate
```

`eth0` and the access point are **ports on one bridge**: the wired boards and a laptop on the access point share one L2 domain and one DHCP server, and reach `tcp/10.42.0.1:7447` without the compute node routing between them.

The Nerves boards are dual-homed by their firmware: `eth0` takes its lease from `ovcs0` and carries the fabric; `wlan0` joins whichever of the application's `WIFI_NETWORKS` (in `vehicles/<app>/.env.exs`) is in range and carries everything a person does. VintageNet prefers the wired route when both are up. Nothing on the fabric depends on the site Wi-Fi: unplug it and the vehicle keeps driving; take the vehicle elsewhere and every board is still reachable through the access point.

The compute node's uplink isn't load-bearing either. `method=shared` assigns the bridge address, starts dnsmasq and installs the NAT rule unconditionally; with the uplink down, clients still get leases and full vehicle-local connectivity, just no route off the vehicle.

One piece of the vehicle network is a container rather than a keyfile: `bridge_nat_fix` in [`compose/compute/docker-compose.yml`](../compose/compute/docker-compose.yml). balena-engine switches `bridge-nf-call-iptables` on, so frames `ovcs0` forwards between `eth0` and the access point traverse iptables, where `method=shared`'s MASQUERADE rewrites anything not addressed to `10.42.0.0/24`, multicast included. A laptop's mDNS query then reaches the wire from the bridge's address on a random port, the board answers it as a legacy unicast query, and the laptop discards the reply for not coming from port 5353: `ovcs-mini-vms.local` resolves from the site Wi-Fi and fails from the access point, with nothing logged. The container inserts one rule ahead of NetworkManager's (traffic leaving through `ovcs0` isn't translated) and re-asserts it every 30 s, since NetworkManager rewrites its nat rules whenever the connection is re-activated.

Keyfile templates live in [`compose/compute/host/system-connections/`](../compose/compute/host/system-connections/); each file's comments explain its settings. Two constraints aren't obvious:

- **The bridge can't be called `br0`.** balenaOS's `NetworkManager.conf` lists `interface-name:br*` as unmanaged, so activation fails with `device is strictly unmanaged`.
- **The 5 GHz access point needs `wifi_ap_fix`.** On channel 149 at 80 MHz, NetworkManager 1.52 generates an invalid VHT center frequency (5770 MHz). The `wifi_ap_fix` service corrects it to 5775 MHz through the host supplicant's D-Bus interface and reapplies the 6 dBm TX limit. `compose/compute/host/configure-5ghz.sh` installs the 5 GHz profile plus `ovcs0-ap-fallback`, a 2.4 GHz clone that takes over when 5 GHz can't start. Deploy the service before running it; see the [host instructions](../compose/compute/host/README.md). Keep the configured regulatory country, and account for antenna gain when changing power.

### Reaching the vehicle network from the site Wi-Fi

A laptop on the site Wi-Fi reaches each Nerves board directly at its site address, by mDNS: `ping ovcs-mini-vms.local`, `./ovcs connect ovcs_mini vms`, the dashboard at `http://ovcs-mini-vms.local:4000`. Foxglove attaches to the compute node's site address (its `uplink` lease; reserve it on the site router for a stable URL).

That laptop has no route into `10.42.0.0/24`: `method=shared` masquerades outbound traffic and forwards nothing in, so `ping 10.42.0.1` fails. Two ways in:

- **Join the access point.** It puts the laptop on the fabric itself: needed for anything that must see the wire (a `z_sub` against the router, a board whose Wi-Fi is down), and the better path for Foxglove when the stereo streams saturate the compute node's onboard radio.
- **Hop through the compute node for SSH.** The balenaOS host is on both networks and its sshd forwards, so one block in `~/.ssh/config` makes every wired address reachable for `ssh`, and therefore for `./ovcs upload` and `./ovcs connect --host`.

```text
Host 10.42.0.*
    ProxyJump root@<compute node site address>:22222
    StrictHostKeyChecking accept-new
```

Only SSH goes through the hop, and the compute node's site address is a lease, so the block follows it. It is how you reflash a board whose own Wi-Fi isn't configured yet.

### Why not relay the site Wi-Fi onto the wire

The alternative (the AX210 as a *client* of the site Wi-Fi, the wired switch on that same network) doesn't hold up:

- A Wi-Fi station can't be a port of a Linux bridge (802.11 frames carry three addresses, so the access point drops anything whose source MAC isn't the station's), which leaves proxy ARP plus a DHCP relay. Proxy ARP works, but guest networks and consumer routers commonly ignore relayed DHCP requests. What's left is a local pool inside the site's subnet (a collision risk) or impersonating each board at the DHCP level.
- Even when it works, the router address baked into the bridge firmwares becomes the AX210's *lease*: every new site means a reservation on someone else's router or a firmware rebuild, and no site in range means no fabric.

Giving each board its own Wi-Fi removes the shared radio: real leases for everyone, native mDNS on both networks, a constant router address, and a fabric that doesn't need the site.

### Installing it

Prerequisite: deploy the `wifi_firmware` service in [`compose/compute/docker-compose.yml`](../compose/compute/docker-compose.yml) and reboot once, or the AX210 has no driver bound and `wlP1p1s0` doesn't exist.

**Two directories are in play, on different filesystems.** `/mnt/boot/system-connections/` (vfat, the boot partition) is the source of truth: `balena-net-config` runs on every boot and does

```sh
cp -r "${BALENA_BOOT_MOUNTPOINT}/system-connections/" /etc/NetworkManager/
chmod 600 /etc/NetworkManager/system-connections/*
```

so it overwrites the live copies each time. NetworkManager only reads `/etc/NetworkManager/system-connections/` (bind-mounted from the state partition), so a keyfile dropped in `/mnt/boot` is invisible to `nmcli connection reload` until the next reboot. The steps below write both places: `/mnt/boot` so the configuration survives, `/etc` so it activates without a reboot.

`eth0` is the maintenance link on a fresh install and changes last: phase 1 can't cost you access to the device, phase 2 can.

#### Phase 1: the access point and the uplink

Nothing here touches `eth0`, so the maintenance link and the balena cloud tunnel stay up. Copy `ovcs0`, `ovcs0-ap` and `uplink` into **both** directories, then:

1. Fill in the access point's SSID and PSK, and the site Wi-Fi's in `uplink`. The filled copies are gitignored.
2. Add the regulatory domain to `/mnt/boot/config.json`, e.g. `"country": "BE"`. `balena-net-config` turns it into `iw reg set` at boot; without it the card sits in domain `00`, where AP mode can't beacon. It is a `config.json` key, not a `BALENA_HOST_CONFIG_*` variable.

   Edit it with `jq` and compare the key count before and after: the file also holds the device's API keys, and a truncated write is a device that no longer provisions. `balena-config-vars` sources `$BALENA_CONFIG_VARS_CACHE` whenever that file exists, without comparing mtimes, so verify with `balena-config-vars --no-cache`. The value reaches the driver at the next boot.
3. `chmod 600` the `/etc` copies and `nmcli connection reload`.
4. `nmcli con up uplink && nmcli -f IP4.ADDRESS con show uplink`. That address is the way in from now on; open a second SSH session on it.
5. `nmcli con up ovcs0`. Join the access point from a laptop and check it gets a lease in `10.42.0.0/24` and reaches `10.42.0.1`.
6. Reboot and check again: keyfile autoconnect at boot is a different code path from `nmcli con up`.

#### Phase 2: bridging eth0

Activating `ovcs0-eth0` turns `eth0` from DHCP client into DHCP *server* and drops the compute node's lease on whatever it is plugged into:

1. Be connected over the `uplink` address, and confirm the cloud tunnel uses it: `ip route get 1.1.1.1` names the onboard radio (`wlan0` or `wlan1`; the `uplink` keyfile explains why it varies).
2. **Move `eth0` to the vehicle's own switch**, disconnected from any other LAN. On a shared LAN it becomes a rogue DHCP server the moment step 3 lands.
3. Copy `ovcs0-eth0` into both directories, `chmod 600` the `/etc` copy, `nmcli connection reload`, `nmcli con up ovcs0-eth0`. Within seconds `/var/lib/NetworkManager/dnsmasq-ovcs0.leases` lists the boards by hostname.
4. Reboot, and confirm `eth0` came back as a bridge port rather than picking up a fresh lease.

Keep `ovcs0-eth0` out of `/mnt/boot/system-connections/` until step 3: everything there autoconnects at boot, so staging it early means a reboot performs phase 2 for you.

#### The boards

Put the site Wi-Fi in `WIFI_NETWORKS` in `vehicles/<app>/.env.exs` and set `ZENOH_ENDPOINT_IP` to the bridge address (see [Wiring it into OVCS](#wiring-it-into-ovcs)). Rebuild and upload every Nerves firmware of the application; boards not yet reflashed are reachable through the [SSH hop](#reaching-the-vehicle-network-from-the-site-wi-fi) at the wired address `dnsmasq-ovcs0.leases` gives them.

#### Checks

```sh
# The AX210's regulatory domain. Address the phy through the interface:
# phy indices follow probe order and swap between boots.
iw phy$(cat /sys/class/net/wlP1p1s0/phy80211/index) reg get | head -2
iw dev wlP1p1s0 info                 # type AP, expected channel
ip -4 addr show ovcs0                # 10.42.0.1/24
ls /sys/class/net/ovcs0/brif/        # eth0 wlP1p1s0
cat /var/lib/NetworkManager/dnsmasq-ovcs0.leases   # one line per board
iptables -t nat -S POSTROUTING | head -2           # ovcs-bridge-no-nat before nm-shared-ovcs0
ip route | grep default              # exactly one, via the onboard radio (wlan0 or wlan1)
journalctl -k -b | grep iwlwifi      # "loaded firmware" and "loaded PNVM"

# From a laptop on the site Wi-Fi, then again on the access point
ping ovcs-mini-vms.local             # site address, then 10.42.0.x
```

The kernel line is the one to keep an eye on: if the boot-time probe races the volume mount and loses, it prints the `ty-a0-gf-a0-77` failure list and the access point silently doesn't exist. The fix would be a privileged service that writes the card's PCI address to `/sys/bus/pci/drivers_probe` on start.

## Wiring it into OVCS

1. Set the compute node up as the vehicle network (see [Networking](#networking)). Its bridge address (`10.42.0.1` in the templates) is the router address.
2. Set `ZENOH_ENDPOINT_IP` to that address in `vehicles/<app>/.env.exs`, and the site Wi-Fi in `WIFI_NETWORKS` next to it.
3. **Rebuild and re-upload every firmware of the application**: the `RosBridge` hosts (`bridge-ros` and `bridge-ros_perception` on the Mini) for the endpoint, and all of them, the VMS included, for the Wi-Fi. The endpoint is baked into application config at build time (`bridges/firmware/config/target.exs`), not read at boot: `.env.exs` only calls `System.put_env` on the build host. A firmware that isn't rebuilt keeps peering with the old address; one built without `ZENOH_ENDPOINT_IP` falls back to `127.0.0.1`, where no router listens.
4. Point the base station at it: `ZENOH_ENDPOINT_IP` in `compose/local/.env` (`10.42.0.1` from a laptop on the access point, the compute node's site address otherwise), and Foxglove Studio at `ws://<compute node address>:8765`.

Because the compute node hands out the addresses, the router address is a constant and step 3 is one-time setup. Adding a site to `WIFI_NETWORKS` still means a rebuild.

`zenohex 0.9.0`, which `ros_bridge` depends on, pins zenoh **1.9.0**, the same version as the `eclipse/zenoh:1.9.0` router image. Bump them together.

## Clock

Every publisher on the fabric stamps its samples with a nanosecond source timestamp (`Ros2.RmwZenoh.attachment/3` on the Elixir side), and consumers act on them: Foxglove orders everything it displays by them, and the stereo calibrator pairs left and right frames within `APPROXIMATE_SYNC` (50 ms by default). The clocks have to agree *across machines*, not just be monotonic on each.

The Nerves bridges get this from `nerves_time`, which also floors the clock at the firmware's build time so a network-less boot is stale rather than nonsense. The compute node needs the equivalent: NTP once the network is up, and the Pi 5's RTC battery fitted so the window before that isn't spent publishing timestamps from an arbitrary epoch.

## Two update paths

- Nerves firmwares: `./ovcs upload <app> <role>` (see [Running on hardware](./running_hardware.md)).
- The compute node: `balena push`, or an OTA from the fleet.

The gamepad (`joy`) stays on the base station, in `compose/local/base.yml`: the round trip pad → ROS → Zenoh → `RosBridge.Consumers.Joy` → CAN is the price of keeping the controller with the operator.
