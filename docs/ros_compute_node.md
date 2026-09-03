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
| Board | Raspberry Pi 5, 8 GB | ROS 2 Lyrical + Foxglove + perception nodes want the headroom |
| Storage | NVMe (HAT) or USB SSD | ROS images are multi-GB and container writes destroy SD cards |
| Clock | Pi 5 RTC connector + battery, plus NTP | see [Clock](#clock) |
| Network | the Pi *is* the vehicle network — see [Networking](#networking) | the bridges' router IP is baked into firmware, so it has to be an address we choose |
| Wi-Fi card | Intel AX210 (M.2 → PCIe), **plus** the onboard radio | the AX210 serves the access point; the onboard radio is the optional internet feed |

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

## Networking

The Pi *is* the vehicle network. It runs the access point, the DHCP
server and the gateway, so the fabric exists as soon as the car has
power — no infrastructure to be in range of, and an address for the
Zenoh router that we choose rather than lease.

```
                        internet (optional)
                              │
                wlan0 ── onboard Broadcom, client, default route
                              │  NAT
        ┌─────────────────────┴──────────────────────────┐
        │  ovcs0   10.42.0.1/24    NetworkManager bridge │
        │    ipv4.method=shared →                        │
        │      dnsmasq: DHCP .10-.254 + DNS              │
        │      MASQUERADE out via wlan0                  │
        └────┬────────────────────────────┬──────────────┘
             │                            │
          eth0                      wlP1p1s0  (AX210 AP, 2.4 GHz)
     Nerves bridges                 base station laptop
```

`eth0` and the access point are **ports on one bridge**, so the wired
bridges and the wireless base station are a single L2 domain served by
a single DHCP server, reachable at `tcp/10.42.0.1:7447` from either
side without the Pi having to route between them.

That is the end state. **`eth0` joins last, and deliberately so** — the
diagram above is where this is going, not where a fresh install starts.
Until it is bridged, eth0 stays an ordinary DHCP client, which keeps it
usable as the maintenance link while the access point is brought up and
exercised. The two phases in [Installing it](#installing-it) reflect
that: phase 1 cannot cost you access to the device, phase 2 can.

The onboard radio is deliberately not load-bearing. `method=shared`
assigns the bridge address, starts dnsmasq and installs the NAT rule
unconditionally; if `wlan0` is unassociated, clients still get leases
and full vehicle-local connectivity and simply have no route off the
car. Only balena OTA, the cloud SSH tunnel and NTP need the uplink.

Keyfile templates live in
[`ros2/vehicule/host/system-connections/`](../ros2/vehicule/host/system-connections/).
Two non-obvious constraints are baked into them, and the comments in
each file explain the rest:

- **The bridge cannot be called `br0`.** balenaOS's
  `NetworkManager.conf` lists `interface-name:br*` as unmanaged, so
  such a bridge is invisible to NetworkManager and activation fails
  with `device is strictly unmanaged`.
- **The access point is 2.4 GHz because that is all the card offers.**
  The AX210 is a self-managed regulatory phy; 5 GHz is either
  `IR-CONCURRENT`, `DFS`, or in a band the ETSI regdb caps at 13 dBm
  and partly allocates to road tolling. A 5 GHz AP here needs a
  different card and hostapd, not a config change.

### Installing it

Prerequisite: the `wifi_firmware` service in
[`../ros2/vehicule/docker-compose.yml`](../ros2/vehicule/docker-compose.yml)
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

#### Phase 1 — the access point

Nothing here touches `eth0`, so the maintenance link and the balena
cloud tunnel stay up throughout. Copy `ovcs0` and `ovcs0-ap` (and
`uplink`, if the onboard radio is wanted as an internet feed — it is
optional and can wait) into **both** directories, then:

1. Fill in the AP SSID and PSK. The filled copies are gitignored.
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
4. `nmcli con up ovcs0`. Join the access point from a laptop and check
   it gets a lease in `10.42.0.0/24` and can reach `10.42.0.1`.
5. Reboot and check the same things again. Keyfile autoconnect at boot
   is a different code path from `nmcli con up`, and this is the first
   time it runs unattended.

While eth0 is still an ordinary DHCP client it also remains the default
route, so `method=shared`'s MASQUERADE rule sends AP clients out
through it. Convenient for testing; it stops being true in phase 2,
which is what `uplink` is for.

#### Phase 2 — bridging eth0

Only when the vehicle is actually being wired up. Activating
`ovcs0-eth0` converts eth0 from DHCP client to DHCP *server* and drops
the Pi's lease on whatever it is plugged into, so:

1. Bring up `uplink` first and confirm the cloud tunnel survives on it
   — it becomes the only way in if the wired side goes wrong:
   `nmcli con up uplink && ip route get 1.1.1.1`.
2. **Move eth0 to the vehicle's own switch.** On an office LAN this Pi
   would become a rogue DHCP server the moment step 3 lands.
3. Copy `ovcs0-eth0` into both directories, `chmod 600` the `/etc`
   copy, `nmcli connection reload`, `nmcli con up ovcs0-eth0`.
4. Reboot, and confirm eth0 came back as a bridge port rather than
   picking up a fresh lease.

Keep `ovcs0-eth0` out of `/mnt/boot/system-connections/` until step 3.
Everything in that directory autoconnects at boot, so staging it early
means a reboot silently performs phase 2 for you.

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
ls /sys/class/net/ovcs0/brif/        # wlP1p1s0; plus eth0 after phase 2
journalctl -k -b | grep iwlwifi      # "loaded firmware" and "loaded PNVM"
```

That last one is the check worth keeping: if the boot-time probe races
the volume mount and loses, it prints the `ty-a0-gf-a0-77` failure list
again and the access point silently does not exist. The fix if it ever
happens is a privileged service that writes the card's PCI address to
`/sys/bus/pci/drivers_probe` on start.

## Wiring it into OVCS

1. Set the Pi up as the vehicle network — see [Networking](#networking).
   Its bridge address (`10.42.0.1` in the templates) is the router
   address, and it is chosen rather than leased.
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

Step 3 used to be the recurring cost of this design, because the
address was whatever DHCP handed out. Now that the Pi hands out the
addresses, the router address is a constant and step 3 is a one-time
setup step rather than something a network change re-triggers. Making
the endpoint runtime-resolvable is still the nicer answer, but it is no
longer urgent.

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

**Phase 1 is done and proven across a reboot** on the Mini's Pi. The
`wifi_firmware` service stages the blobs and iwlwifi binds them at boot
("loaded firmware version 89…", "loaded PNVM version…"); `"country":
"BE"` reaches the AX210's self-managed phy; `OVCS-Mini` comes up
unattended on ch 11 as `WPA2 WPA3`, confirmed beaconing by scanning
for it from the onboard radio; `ovcs0` holds `10.42.0.1/24` with
dnsmasq leasing `.10-.254`, and a client has been given an address.
The onboard radio reconnects as the uplink. `eth0` is untouched and
still the default route.

What is left:

1. Decide whether HT40 is worth it. `channel-width` is auto (HT20)
   today; HT40 roughly doubles throughput for Foxglove but needs
   ch 3-9, which is where the site's other APs already are.
2. Phase 2 — bridge `eth0` per
   [Installing it](#installing-it), set `ZENOH_ENDPOINT_IP` to the
   bridge address in `vehicles/ovcs_mini/.env.exs`, and rebuild
   `bridge-ros` and `bridge-ros_perception` once.

Next: [Running on Hardware](./running_hardware.md)
