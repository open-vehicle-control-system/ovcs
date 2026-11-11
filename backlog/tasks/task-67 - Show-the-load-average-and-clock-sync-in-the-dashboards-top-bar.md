---
id: TASK-67
title: Show the load average and clock sync in the dashboards' top bar
status: Done
assignee:
  - '@claude'
created_date: '2026-11-11 12:35'
labels:
  - ovcs
  - vision
dependencies: []
ordinal: 62000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`OvcsTopBar` (`libraries/ovcs_ui`) shows what the firmware answers about itself, read once per connection: version, system and vehicle. It shows nothing about the board's health.

A board whose clock is not synchronized publishes nothing to ROS 2 (`Ros2Zenoh.Client`), yet every status reads healthy: the ROS 2 exporter shows `Connected` and `/api/ros2-node` lists topic rates for messages the client drops. The top bar should say so, and show the load average next to it.

- Load average: the 1, 5 and 15 minute figures of `/proc/loadavg`.
- Clock: synchronized or not (`NervesTime.synchronized?/0` on a board; a host reports none).

Both change while the dashboard is open, so they need a live source (the status channel or a periodic read), not the per-connection firmware read.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The VMS and vision APIs report the load average and whether the clock is synchronized, documented in their API guides
- [x] #2 `OvcsTopBar` shows the load average and the clock's state, updated while the dashboard is open
- [x] #3 An unsynchronized clock stands out as a warning in the top bar
- [x] #4 On a host, the clock's state is omitted rather than shown as unsynchronized
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
`GET /api/board` (TASK-69) carries both, with the CPU's busy share over a half-second sample; `OvcsTopBar` shows them as CPU and Load next to the board's addresses and clock. `OvcsVehicle.SystemLoad`, moved from vision_core, reads both for every board, and the vision dashboard's bottom bar no longer shows the CPU, which the top bar now shows on every dashboard.
<!-- SECTION:NOTES:END -->
