---
id: TASK-69
title: Show the board's addresses and clock in the dashboards' top bar
status: Done
assignee:
  - '@claude'
created_date: '2026-11-11 15:10'
labels:
  - ovcs
dependencies: []
ordinal: 64000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`OvcsTopBar` shows the firmware a board runs, but not how to reach it or whether its clock can be trusted: a board whose clock is not synchronized publishes nothing to ROS 2, and its addresses change with the network it joins.

Chosen: `OvcsVehicle.BoardStatus` reads the interfaces that are up and running with their addresses (loopback and IPv6 link-local left out) and the clock: its UTC time and whether NTP synchronized it (`NervesTime.synchronized?/0`), unknown on a host. The VMS and vision APIs serve it as `GET /api/board`. The top bar reads it every 10 s while connected, shows each interface's addresses and the board's clock, ticking from the offset measured at the last read, and marks an unsynchronized clock as a warning.

The load average stays with TASK-67.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `OvcsVehicle.BoardStatus.current/1` lists the running interfaces with their addresses and the clock's time and synchronization, `nil` without NervesTime
- [x] #2 The VMS and vision APIs serve it as `GET /api/board`, documented in their API guides
- [x] #3 `OvcsTopBar` shows each interface's addresses and the board's clock, read while the dashboard is connected
- [x] #4 An unsynchronized clock stands out as a warning; on a host the synchronization is not shown
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
An interface is listed when it has a device in `/sys/class/net`, is up and running, and has an address: Erlang reports a container bridge as running even with nothing attached, and a host's Docker bridges otherwise fill the bar. On the Arduino VENTUNO Q the bar lists `eth0`, `usb0` and `wlan0` with their addresses; the clock reads not synchronized for about 30 s after boot, then synchronized.
<!-- SECTION:NOTES:END -->
