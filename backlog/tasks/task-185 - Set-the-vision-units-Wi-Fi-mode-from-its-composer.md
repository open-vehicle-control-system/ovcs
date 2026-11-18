---
id: TASK-185
title: Set the vision unit's Wi-Fi mode from its composer
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T11:45:00Z'
labels:
  - vision
  - firmware
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A vehicle's vision unit has to be reachable from a phone wherever the vehicle is. In the workshop it joins the site Wi-Fi; in a car under test there is none, and the unit hosts its own network; in a finished car it is on the vehicle's Ethernet and its radio stays off. Today `wlan0` is configured at build time from `WIFI_NETWORKS` and can only join networks.

Options:

- A `wifi:` field in `VisionCore.Config`, applied by the vision firmware at boot with `persist: false`. A pure function from the mode to VintageNet's configuration is tested on the host, and `vision_core` keeps no hardware code.
- `config/runtime.exs` writing `:vintage_net`'s application config from the composer: less code, but a configuration VintageNet saved earlier takes precedence over it, so a changed mode could go unapplied.

Chosen: the `wifi:` field.

| `wifi:` | `wlan0` |
|---|---|
| `:join` (the default) | joins the networks of `WIFI_NETWORKS` by DHCP; unconfigured when there are none |
| `{:hotspot, ssid: "..."}` | hosts that network, WPA2 with `WIFI_HOTSPOT_PSK`, at `192.168.4.1/24` on channel 6, handing out `.10` to `.50` |
| `:off` | unconfigured |

`OvcsVehicle.Wifi` maps a mode to the configuration and applies it once; `OvcsVehicle.Application` starts it when the firmware sets `:ovcs_vehicle, :wifi_mode`, which the vision firmware's `config/runtime.exs` reads from its composer on a board. The mode then applies once VintageNet runs, whether or not `vision_core` starts, and `config/target.exs` no longer configures `wlan0`. The release refuses a hotspot without a passphrase WPA2 takes, 8 to 63 printable ASCII characters; on the unit, a mode it cannot apply, or one VintageNet refuses, leaves `wlan0` unconfigured and is logged. OVCS1's composer hosts `ovcs1-vision`. The VENTUNO Q's QCA2066 (`ath11k_pci`) hosts such a network: a phone joined it and loaded the dashboard.

Out of scope: joining and hosting at once, switching modes on its own, internet through the hotspot, and the other firmwares.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The composer's `wifi:` sets `wlan0` to join the site networks, host a hotspot, or stay off
- [x] #2 Every boot applies the composer's mode, including after a firmware upload that changes it
- [x] #3 The build refuses a hotspot without a passphrase WPA2 takes, and a mode the unit cannot apply leaves `wlan0` unconfigured and is logged
- [ ] #4 On OVCS1's hotspot, a phone gets an address and opens the dashboard at `https://192.168.4.1`
- [x] #5 The mode applies whether or not the vision pipeline starts
<!-- AC:END -->
