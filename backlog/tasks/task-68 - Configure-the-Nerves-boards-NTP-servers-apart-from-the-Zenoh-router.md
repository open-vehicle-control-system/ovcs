---
id: TASK-68
title: Configure the Nerves boards' NTP servers apart from the Zenoh router
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-11 12:50'
labels:
  - ovcs
dependencies: []
ordinal: 63000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The vision, bridges and VMS firmwares put `ZENOH_ENDPOINT_IP` first in `:nerves_time, :servers`. A vehicle without a compute node, such as OVCS1, or a router running on a development machine, makes the boards ask a host that serves no time.

Options:

- Keep the router first by default and let `NTP_SERVERS` override the list.
- `NTP_SERVERS` alone sets the list; the public pools when unset.

Chosen: `NTP_SERVERS` alone, comma-separated, from the vehicle's `.env.exs`, the public pools when unset. The router address and the time source are separate facts; a vehicle with a compute node lists it first.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The vision, bridges and VMS firmwares read their NTP servers from `NTP_SERVERS` and use the public pools when it is unset
- [ ] #2 `ZENOH_ENDPOINT_IP` no longer changes the NTP servers
- [ ] #3 The OVCS Mini's `.env.exs.example`, the glossary, Running on hardware and the compute node guide describe `NTP_SERVERS`
- [ ] #4 OVCS1's vision unit, built with `ZENOH_ENDPOINT_IP` set and no `NTP_SERVERS`, lists only the public pools
<!-- AC:END -->
