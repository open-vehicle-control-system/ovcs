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
both sides live in [`compose/`](../compose/README.md): what runs here
in `compose/compute/`, what never leaves a workstation in
`compose/local/`.

## Hardware

| Item | Choice | Why |
|---|---|---|
| Board | Raspberry Pi 5, 8 GB | ROS 2 Lyrical + Foxglove + perception nodes want the headroom |
| Storage | NVMe (HAT) or USB SSD | ROS images are multi-GB and container writes destroy SD cards |
| Clock | Pi 5 RTC connector + battery, plus NTP | see [Clock](#clock) |
| Network | the compute node *is* the vehicle network; every board also joins the site Wi-Fi on its own — see [Networking](#networking) | the bridges' router IP is baked into firmware, so it has to be an address we choose |
| Wi-Fi card | Intel AX210 (M.2 → PCIe), **plus** the onboard radio | the AX210 serves the access point; the onboard radio joins the site Wi-Fi |

This is a **new Pi**, not a repurposed one:

- The **VMS Pi 4** is vehicle control. Coupling it to the ROS fabric
  puts a container runtime in the safety path.
- The **`ros_perception` Pi 5** already runs the stereo + Hailo
  pipeline as Nerves + Elixir (`vehicles/ovcs_mini/lib/ovcs_mini.ex`,
  `bridge_firmwares/0` — SGBM depth on the CPU, YOLO detection on the
  accelerator; see `docs/ros_perception_detection.md`). It stays as it
  is; it joins the fabric as a client like the other bridges.

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
  becomes a file next to `compose/`, generations give atomic rollback,
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
cd compose/compute
balena push <fleet>            # build on balena's builders, OTA to the fleet
balena push <device>.local     # local mode: build on the device, no cloud
```

A local-mode push that is interrupted — by a reboot, say — can leave
the built image **untagged** while `local_image_<service>:latest` still
resolves to the previous one. The supervisor then faithfully runs the
old image, and the symptom is a fix that visibly does not take even
though the build succeeded. Check the tag, not the build output:

```sh
balena-engine images --no-trunc --format '{{.Repository}}:{{.Tag}} -> {{.ID}}' \
  | grep <service>
balena-engine inspect $(balena-engine ps -aq --filter name=<service> | head -1) \
  --format '{{json .Config.Cmd}}'
```

Local-mode pushes also leave the fleet's target state untouched, so
nothing reaches the other devices until the same code is pushed to the
fleet rather than to `<device>.local`.

`compose/compute/` is the balena **source root**. That is not cosmetic:
`balena push` only reads a file literally named `docker-compose.yml` at
the root of the pushed directory, and every `build:` context must sit
inside that directory. This is why every image the car runs lives under
`compose/compute/images/` and the local stacks reach across to build
the same ones, and not the other way round. The root also carries a
`.dockerignore`: the pushed tarball is what OTA deltas are computed
from, so `host/` and the README stay out of it.

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
`compose/compute/docker-compose.yml` is written to stay inside it, and
the differences from `compose/local/*.yml` are all forced:

| Not usable on balena | Consequence |
|---|---|
| host bind mounts | no `./workspace` on the vehicle — nodes ship **in the image** |
| `container_name` | the supervisor names containers |
| `profiles:` | one file, one always-on set of services |
| `device_cgroup_rules` | hot-plug device tricks need `privileged` / balena labels instead |
| shared image tags across services | every custom-image service carries its own `build:` |
| BuildKit | no `COPY --chmod=`, no heredocs, no `RUN --mount` — balenaEngine builds with the classic engine |

YAML anchors, `extends:` and `${VAR:-default}` interpolation are
avoided too — not because they are known to fail, but because they are
unverified against the balena parser and the launcher scripts already
default everything. The local stacks share their Zenoh environment
through `compose/local/common.yml`; the vehicle file spells it out per
service.

## Networking

Two networks, each doing the one thing it is good at:

- **The wire is the vehicle.** The compute node runs the access point,
  the DHCP server and the gateway of `10.42.0.0/24`, so the fabric
  exists as soon as the car has power — no infrastructure to be in
  range of, and an address for the Zenoh router (`10.42.0.1`) that we
  choose rather than lease. The Nerves boards are cabled to it through
  the vehicle switch.
- **The site Wi-Fi is for people.** Every board — the compute node
  through its onboard radio, each Nerves board through its own — also
  joins the site's Wi-Fi as an ordinary client. That is where SSH,
  `./ovcs connect`, the VMS dashboard, Foxglove and mDNS live, and
  where internet (balena OTA, the cloud tunnel, NTP) comes from.

```
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
          eth0                      wlP1p1s0  (AX210 AP "OVCS-Mini", 5 GHz)
     vehicle switch:                a laptop with no site Wi-Fi,
     VMS, bridge-ros,               or one that wants the fabric
     bridge-ros_perception          at full rate
```

`eth0` and the access point are **ports on one bridge**, so the wired
boards and a laptop on the access point are a single L2 domain served
by a single DHCP server, reachable at `tcp/10.42.0.1:7447` from either
side without the compute node having to route between them.

The Nerves boards are dual-homed by their firmware: `eth0` takes its
lease from `ovcs0` and carries the fabric; `wlan0` joins whichever of
the vehicle's `WIFI_NETWORKS` (in `vehicles/<vehicle>/.env.exs`) is in
range and carries everything a person does. VintageNet prefers the
wired route when both are up, and the Zenoh endpoint is on the wire in
any case. Nothing on the fabric depends on the site Wi-Fi: unplug it
and the car keeps driving; take the car somewhere else and every Nerves
board is still reachable through the access point.

The onboard radio of the compute node is deliberately not load-bearing
either. `method=shared` assigns the bridge address, starts dnsmasq and
installs the NAT rule unconditionally; if the uplink is unassociated,
clients still get leases and full vehicle-local connectivity and simply
have no route off the car.

One piece of the vehicle network is not a keyfile but a container:
`bridge_nat_fix` in
[`compose/compute/docker-compose.yml`](../compose/compute/docker-compose.yml).
balena-engine switches `bridge-nf-call-iptables` on, so frames `ovcs0`
forwards between `eth0` and the access point traverse iptables, where
`method=shared`'s MASQUERADE rewrites anything not addressed to
`10.42.0.0/24` — multicast included. A laptop's mDNS query then reaches
the wire from the bridge's address on a random port, the board answers
it as a legacy unicast query, and the laptop's resolver discards the
reply for not coming from port 5353. `ovcs-mini-vms.local` works from
the site Wi-Fi and fails from the vehicle's own access point, with
nothing in any log. The container inserts one rule ahead of
NetworkManager's — traffic leaving through `ovcs0` is not translated —
and re-asserts it every 30 s, since NetworkManager rewrites its nat
rules whenever the connection is re-activated.

Keyfile templates live in
[`compose/compute/host/system-connections/`](../compose/compute/host/system-connections/).
Two non-obvious constraints are baked into them, and the comments in
each file explain the rest:

- **The bridge cannot be called `br0`.** balenaOS's
  `NetworkManager.conf` lists `interface-name:br*` as unmanaged, so
  such a bridge is invisible to NetworkManager and activation fails
  with `device is strictly unmanaged`.
- **The access point uses channel 149 at 80 MHz.** NetworkManager 1.52
  generates an invalid VHT center frequency of 5770 MHz for this channel.
  The `wifi_ap_fix` service corrects it to 5775 MHz through the host
  supplicant's D-Bus interface and reapplies the tested 6 dBm TX limit.
  Keep the configured regulatory country and account for antenna gain
  when changing power. Deploy the service before installing the 5 GHz
  profile; see the [host instructions](../compose/compute/host/README.md).

### Reaching the vehicle network from the site Wi-Fi

A laptop on the site Wi-Fi reaches each Nerves board directly, at its
own site address, by mDNS: `ping ovcs-mini-vms.local`, `./ovcs connect
ovcs_mini vms`, the dashboard at `http://ovcs-mini-vms.local:4000`.
Foxglove attaches to the compute node's site address (the `uplink`
lease — reserve it on the site router for the onboard radio's MAC if a stable URL
matters).

What that laptop does *not* have is a route into `10.42.0.0/24`:
`method=shared` masquerades outbound traffic and forwards nothing in,
so `ping 10.42.0.1` fails and a board's wired address is unreachable.
The two ways in:

- **Join the access point.** `OVCS-Mini` puts the laptop on the fabric
  itself — needed for anything that must see the wire (a `z_sub`
  against the router, a board whose Wi-Fi is down), and the better
  path for Foxglove when the stereo streams saturate the compute
  node's onboard radio.
- **Hop through the compute node for SSH.** The balenaOS host is on
  both networks and its sshd forwards, so one block in `~/.ssh/config`
  makes every wired address reachable for `ssh`, and therefore for
  `./ovcs upload` and `./ovcs connect --host`, which run `ssh`
  underneath:

  ```
  Host 10.42.0.*
      ProxyJump root@<compute node site address>:22222
      StrictHostKeyChecking accept-new
  ```

  Only SSH goes through it — nothing else on the laptop sees
  `10.42.0.0/24` — and the compute node's site address is a lease, so
  the block follows it. It is the way to reflash a board whose own
  Wi-Fi is not configured yet, without changing the laptop's network.

### Why not relay the site Wi-Fi onto the wire

The obvious alternative — the AX210 as a *client* of the site Wi-Fi,
the wired switch placed on that same network — was built and tested on
the car, and is not the design for two reasons worth keeping:

- A Wi-Fi station cannot be a port of a Linux bridge (802.11 frames
  carry three addresses, so the access point drops anything whose
  source MAC is not the station's; NetworkManager will not enslave a
  station), which leaves a layer-3 imitation: proxy ARP plus a DHCP
  relay. The proxy ARP half works — the site's access point accepted
  several addresses behind the card's MAC — but its **DHCP server
  ignored every relayed request**, broadcast or unicast, as guest
  networks and consumer routers commonly do. The remaining options were
  a local pool inside the site's subnet (a collision risk on any
  network whose DHCP range is unknown) or impersonating each board at
  the DHCP level, both of them workarounds for sharing one radio.
- Even when it works, the router address baked into the bridge
  firmwares becomes the AX210's *lease*, so every new site means a
  reservation on someone else's router or a firmware rebuild, and no
  site in range means no fabric at all.

Giving each board its own Wi-Fi removes the shared radio, and with it
the whole problem: real leases for everyone, mDNS native on both
networks, a constant router address, and a fabric that does not need
the site.

### Installing it

Prerequisite: the `wifi_firmware` service in
[`compose/compute/docker-compose.yml`](../compose/compute/docker-compose.yml)
must have been deployed and the device rebooted once, or the AX210 has
no driver bound and `wlP1p1s0` does not exist.

**Two directories are in play, and they are not the same filesystem.**
`/mnt/boot/system-connections/` (vfat, the boot partition) is the
source of truth: `balena-net-config` runs on every boot and does

```sh
cp -r "${BALENA_BOOT_MOUNTPOINT}/system-connections/" /etc/NetworkManager/
chmod 600 /etc/NetworkManager/system-connections/*
```

so it overwrites the live copies each time and sets the permissions
itself. But NetworkManager only ever *reads*
`/etc/NetworkManager/system-connections/` (bind-mounted from the state
partition). A keyfile dropped in `/mnt/boot` and then
`nmcli connection reload`ed is invisible until the next reboot — which
is why the sequences below write both places: `/mnt/boot` so the
configuration survives, `/etc` so it can be activated without a reboot.

`eth0` is the maintenance link on a fresh install and changes last:
phase 1 cannot cost you access to the device, phase 2 can.

#### Phase 1 — the access point and the uplink

Nothing here touches `eth0`, so the maintenance link and the balena
cloud tunnel stay up throughout. Copy `ovcs0`, `ovcs0-ap` and `uplink`
into **both** directories, then:

1. Fill in the AP SSID and PSK, and the site Wi-Fi's in `uplink`. The
   filled copies are gitignored.
2. Add the regulatory domain to `/mnt/boot/config.json` —
   `"country": "BE"`. `balena-net-config` turns that into
   `iw reg set "$COUNTRY"` at boot. Without it the card sits in domain
   `00`, where AP mode cannot beacon at all. It is a `config.json` key,
   not a `BALENA_HOST_CONFIG_*` variable.

   Edit it with `jq` and check the key count before and after — it also
   holds the device's API keys, and a truncated write is a device that
   no longer provisions. Then beware the cache: `balena-config-vars`
   sources `$BALENA_CONFIG_VARS_CACHE` whenever that file exists and
   never compares mtimes, so a shell that reads `$COUNTRY` right after
   the edit can still report the old (empty) value. Use
   `balena-config-vars --no-cache` to verify, and remember the value
   only reaches the driver at the next boot.
3. `chmod 600` the `/etc` copies and `nmcli connection reload`.
4. `nmcli con up uplink && nmcli -f IP4.ADDRESS con show uplink` — this address is the
   way in from now on; open a second SSH session on it.
5. `nmcli con up ovcs0`. Join the access point from a laptop and check
   it gets a lease in `10.42.0.0/24` and can reach `10.42.0.1`.
6. Reboot and check the same things again. Keyfile autoconnect at boot
   is a different code path from `nmcli con up`, and this is the first
   time it runs unattended.

#### Phase 2 — bridging eth0

Activating `ovcs0-eth0` converts `eth0` from DHCP client to DHCP
*server* and drops the compute node's lease on whatever it is plugged
into, so:

1. Be connected over the `uplink` address, and confirm the cloud tunnel
   is on it: `ip route get 1.1.1.1` should name the onboard radio
   (`wlan0` or `wlan1` — see the `uplink` keyfile for why it varies).
2. **Move `eth0` to the vehicle's own switch**, with the switch
   disconnected from any site LAN. On an office LAN this would become
   a rogue DHCP server the moment step 3 lands.
3. Copy `ovcs0-eth0` into both directories, `chmod 600` the `/etc`
   copy, `nmcli connection reload`, `nmcli con up ovcs0-eth0`. Within
   seconds `/var/lib/NetworkManager/dnsmasq-ovcs0.leases` lists the
   boards, by hostname.
4. Reboot, and confirm eth0 came back as a bridge port rather than
   picking up a fresh lease.

Keep `ovcs0-eth0` out of `/mnt/boot/system-connections/` until step 3.
Everything in that directory autoconnects at boot, so staging it early
means a reboot silently performs phase 2 for you.

#### The boards

Put the site Wi-Fi in `WIFI_NETWORKS` in `vehicles/<vehicle>/.env.exs`
and set `ZENOH_ENDPOINT_IP` to the bridge address — see
[Wiring it into OVCS](#wiring-it-into-ovcs). Rebuild and upload every
Nerves firmware of the vehicle; boards that have not been reflashed yet
are reachable for the upload through the
[SSH hop](#reaching-the-vehicle-network-from-the-site-wi-fi) at the
wired address `dnsmasq-ovcs0.leases` gives them.

#### Checks

```sh
# The AX210's regulatory domain. Address the phy through the interface:
# the phy *indices* are assigned in probe order and do swap between
# boots — `iw reg get | grep -A1 phy#1` will happily show you the
# onboard radio's `country 99` and read as a failure when nothing is
# wrong.
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

That last kernel line is the check worth keeping: if the boot-time
probe races the volume mount and loses, it prints the
`ty-a0-gf-a0-77` failure list again and the access point silently does
not exist. The fix if it ever happens is a privileged service that
writes the card's PCI address to `/sys/bus/pci/drivers_probe` on start.

## Wiring it into OVCS

1. Set the compute node up as the vehicle network — see
   [Networking](#networking). Its bridge address (`10.42.0.1` in the
   templates) is the router address, chosen rather than leased.
2. Set `ZENOH_ENDPOINT_IP` to that address in
   `vehicles/ovcs_mini/.env.exs`, and the site Wi-Fi in
   `WIFI_NETWORKS` next to it.
3. **Rebuild and re-upload every firmware of the vehicle** — the
   `RosBridge` hosts (`bridge-ros`, `bridge-ros_perception` on the
   Mini) for the endpoint, and all of them, the VMS included, for the
   Wi-Fi. The endpoint is
   baked into application config at build time
   (`bridges/firmware/config/target.exs`), not read at boot: `.env.exs`
   only `System.put_env`s on the build host, so the device-side
   `System.get_env` returns nil. Two failure modes follow — a firmware
   that isn't rebuilt keeps peering with the *old* address, and one
   built without `ZENOH_ENDPOINT_IP` set falls back to `127.0.0.1`,
   where no router is listening.
4. Point the base station at it: `ZENOH_ENDPOINT_IP` in
   `compose/local/.env` (`10.42.0.1` from a laptop on the access
   point, the compute node's site address otherwise), and Foxglove
   Studio at `ws://<compute node address>:8765`.

Step 3 used to be the recurring cost of this design, because the
address was whatever DHCP handed out. Now that the compute node hands
out the addresses, the router address is a constant and step 3 is a
one-time setup step rather than something a network change re-triggers.
Adding a site to `WIFI_NETWORKS` is the one thing that still means a
rebuild. Making the endpoint runtime-resolvable is still the nicer
answer, but it is no longer urgent.

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

## Where the network stands

**Both phases are installed and proven across a reboot** on the Mini's
compute node. The `wifi_firmware` service stages the blobs and iwlwifi
binds them at boot ("loaded firmware version 89…", "loaded PNVM
version…"); `"country": "BE"` reaches the AX210's self-managed phy;
`OVCS-Mini` comes up unattended as `WPA2 WPA3` — on ch 11 before the
5 GHz profile, on ch 149 / 80 MHz with `wifi_ap_fix` deployed, and the
2.4 GHz clone `ovcs0-ap-fallback` takes over if 5 GHz cannot start;
`ovcs0` holds
`10.42.0.1/24` with `eth0` and the access point as its ports, and
dnsmasq leases to the three Nerves boards by hostname. `uplink` on the
onboard radio is the only default route. Every Nerves firmware is built
with the site Wi-Fi in `WIFI_NETWORKS` and `ZENOH_ENDPOINT_IP=10.42.0.1`:
the boards resolve and answer by mDNS from a laptop on the site Wi-Fi,
and both bridges peer with the router over the wire.

What is left:

1. Confirm the 5 GHz access point survives a cold boot on the car,
   including the fallback path (`ovcs0-ap-fallback` on ch 11 when
   ch 149 does not come up).
2. A reservation on the site router for the compute node's onboard radio, so
   the Foxglove URL stops moving.

Next: [Running on Hardware](./running_hardware.md)
