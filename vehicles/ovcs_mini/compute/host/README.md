# Host-OS configuration for the vehicle's compute node

Everything here configures **balenaOS itself**, not the containers in
[`../docker-compose.yml`](../docker-compose.yml). It is not deployed by
`balena push` — you copy it onto the device once. It lives in the repo
because the alternative is configuring the vehicle's network by hand
over SSH, which is the thing
[`docs/ros_compute_node.md`](../../../../docs/ros_compute_node.md) exists
to avoid.

See [Networking](../../../../docs/ros_compute_node.md#networking) for the
topology these files implement and the install procedure.

## What's here

| File | Role |
|---|---|
| `system-connections/ovcs0.nmconnection.example` | the vehicle bridge — its own gateway + DHCP server |
| `system-connections/ovcs0-ap.nmconnection.example` | the AX210 as a 5 GHz / 80 MHz AP, a bridge port |
| `system-connections/uplink.nmconnection.example` | onboard Wi-Fi as a client of the site network — internet, cloud tunnel, Foxglove |
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
[Installing it](../../../../docs/ros_compute_node.md#installing-it).

## 5 GHz access point

`ovcs0-ap` selects channel 149 at 80 MHz, autoconnect priority 100 and
one autoconnect attempt. NetworkManager 1.52 generates an invalid VHT
center frequency (5770 MHz) for that channel, so the `wifi_ap_fix`
service in the compute stack corrects it to 5775 MHz through the host
supplicant's D-Bus interface and reapplies the 6 dBm transmit-power
limit after driver resets. Deploy the stack before installing the
profile: without the service NetworkManager brings the access point up
on 2.4 GHz instead, with the round-trip times that go with it.

After activation and after a reboot, verify on the host:

```sh
iw dev wlP1p1s0 info
nmcli -f NAME,DEVICE connection show --active
ip route get 1.1.1.1
```

The AP should report channel 149 (5745 MHz), width 80 MHz, center1 5775 MHz,
and 6 dBm. The Internet route should use the onboard `brcmfmac` radio.
