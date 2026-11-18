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

`OvcsVehicle.Wifi` maps a mode to the configuration and applies it once at start; the vision firmware starts it on target with its composer's mode, and `config/target.exs` no longer configures `wlan0`. A hotspot without a passphrase of at least 8 characters is not started: `wlan0` stays unconfigured and the unit logs why. OVCS1's composer hosts `ovcs1-vision`. The VENTUNO Q's QCA2066 (`ath11k_pci`) hosts such a network: a phone joined it and loaded the dashboard.

Out of scope: joining and hosting at once, switching modes on its own, internet through the hotspot, and the other firmwares.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The composer's `wifi:` sets `wlan0` to join the site networks, host a hotspot, or stay off
- [ ] #2 Every boot applies the composer's mode, including after a firmware upload that changes it
- [ ] #3 A hotspot without a passphrase of at least 8 characters leaves `wlan0` unconfigured and logs why
- [ ] #4 On OVCS1's hotspot, a phone gets an address and opens the dashboard at `https://192.168.4.1`
<!-- AC:END -->
