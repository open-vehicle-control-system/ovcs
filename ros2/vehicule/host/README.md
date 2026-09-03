# Host-OS configuration for the ROS compute Pi

Everything here configures **balenaOS itself**, not the containers in
[`../docker-compose.yml`](../docker-compose.yml). It is not deployed by
`balena push` — you copy it onto the device once. It lives in the repo
because the alternative is configuring the vehicle's network by hand
over SSH, which is the thing
[`docs/ros_compute_node.md`](../../../docs/ros_compute_node.md) exists
to avoid.

See [Networking](../../../docs/ros_compute_node.md#networking) for the
topology these files implement and the install procedure.

## What's here

| File | Role |
|---|---|
| `system-connections/ovcs0.nmconnection.example` | the vehicle bridge — its own gateway + DHCP server |
| `system-connections/ovcs0-ap.nmconnection.example` | the AX210 as a 2.4 GHz AP, a bridge port |
| `system-connections/uplink.nmconnection.example` | onboard Wi-Fi as an *optional* internet feed |
| `system-connections/ovcs0-eth0.nmconnection.example` | `eth0` as a bridge port — **installed last**, see below |

The first three are safe to install at any time: they leave `eth0`
alone, so the maintenance link and the balena cloud tunnel survive the
whole bring-up. `ovcs0-eth0` is the one that cannot be undone remotely
— it turns `eth0` from DHCP client into DHCP server — so it waits until
the vehicle is being wired up.

`*.nmconnection` (without `.example`) is gitignored, same arrangement as
`.env.exs` — fill in the SSIDs and PSKs in a local copy and keep the
secrets out of git.

## Where these go on the device

`/mnt/boot/system-connections/` is the source of truth:
`balena-net-config` copies that directory over
`/etc/NetworkManager/system-connections/` on every boot and applies
`chmod 600` itself. NetworkManager only reads the `/etc` copy, so a
file added to `/mnt/boot` does nothing until the next reboot. The
install procedure writes both deliberately — see
[Installing it](../../../docs/ros_compute_node.md#installing-it).
