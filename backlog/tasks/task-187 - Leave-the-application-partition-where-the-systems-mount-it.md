---
id: TASK-187
title: Leave the application partition where the systems mount it
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T13:30:00Z'
labels:
  - firmware
  - vms
  - bridges
  - infotainment
  - reliability
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The OVCS base CAN systems' erlinit mounts the application partition, `/dev/mmcblk0p7`, at `/root`, and `/data` is a link to `/root`. The VMS, bridge and infotainment firmwares added a second erlinit mount at `/data` (the bridges' and infotainment's on `p3`, a boot partition) and set the firmware metadata's application target to `/data` in their `build.sh`.

Nerves Runtime looks the target up by its literal path in `/proc/mounts`, where the partition appears as `/root`: it found it unmounted at every boot, mounted it again (busy), then ran `mkfs.f2fs -f` on it, which refused only because the partition was mounted. Seen on the OVCS Mini's VMS and ROS bridge. The vision firmware, which overrides neither, has `/root` as its target and does none of this.

The firmwares drop both overrides: the systems mount the partition at `/root`, their firmware metadata points Nerves Runtime there, and paths under `/data` keep working through the link.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 No firmware adds an erlinit mount of the application partition or overrides `NERVES_FW_APPLICATION_PART0_TARGET`
- [x] #2 On the OVCS Mini's VMS and ROS bridge, Nerves Runtime finds the partition mounted at boot and neither mounts nor formats it
- [x] #3 The data written before the update is still there after it
<!-- AC:END -->
