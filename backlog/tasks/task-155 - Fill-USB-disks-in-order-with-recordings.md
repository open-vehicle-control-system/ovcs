---
id: TASK-155
title: Fill USB disks in order with recordings
status: In Progress
assignee: []
created_date: '2026-11-14T19:13:00Z'
labels:
  - vision
dependencies: []
ordinal: 108000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PR 4 of the ROS 2 bag exporter, after #352: USB disks (f2fs or ext4) found by their superblock UUID, mounted, ordered and turned on or off in a VisionCore.Models model, filled one after another, ejected.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A recording continues on the next disk when one fills or is pulled out
- [ ] #2 The order survives unplugging and a reboot
- [ ] #3 An ejected disk is unmounted only once the recording has closed its file on it, and stays unmounted while plugged until the unit restarts
- [ ] #4 Each part of a recording is a complete rosbag2 folder
- [ ] #5 Disks work without the database; only saving the order fails
- [ ] #6 A host run never scans the host's disks or runs mount
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Problem: recordings go to `/data/recordings` only; the unit takes USB disks, which Nerves neither mounts nor lists by UUID (no udev, no `/dev/disk/by-uuid`, no `blkid`).

- `VisionCore.Disk`: one disk (UUID, label, filesystem, device, size, free bytes, recordings folder, position, on or off, state) and the superblock reading: f2fs (magic `0xF2F52010` at 1024, UUID at 1132, UTF-16LE label at 1148, `struct f2fs_super_block`) and ext4 (magic `0xEF53` at 1080, UUID at 1128, label at 1144, `struct ext4_super_block`). Anything else is unusable.
- `VisionCore.Models.Disk`, table `disks`: `uuid`, `label`, `filesystem`, `position`, `enabled`, `last_seen_at`. The unit's storage is the row `internal`.
- `VisionCore.Disks`, a process: polls `/sys/block/sd*` every 2 s, reads each new partition's superblock, mounts it at `/data/disks/<uuid>` (`noatime`), adopts a mount already in `/proc/mounts`, lazily unmounts a disk pulled out, reads free space with `df`. Its list is in an ETS table, so `list`, `fetch` and `next` never wait on it while it mounts. `put_order`, `put_enabled`, `eject` (unmounts once `umount` stops answering busy, up to a timeout), `format` (`mkfs.f2fs -f -l`, only an unmounted USB partition).
- Options considered for where `Disks` runs: in the application on every unit, or as the bag exporter's helper (`children/1`). Chosen: the helper, so a unit without the bag exporter mounts nothing, and a crash of `Disks` restarts the exporter, not the cameras. USB scanning is on only in a target build (`VisionCore.arm/0`); tests start it with fake `/sys`, `/dev`, mounts and commands.
- Failover in `Bag.Recording`: with `:disks`, each second it checks its disk; below the 1 GB floor, ejecting, gone, or a write refused, it closes the part and continues in `<name>_part<n>` on the next disk (`Disks.next/3`, excluding every disk it left and any that holds a folder of that name), a complete rosbag2 folder with its own files, schemas, attachments, drops and `metadata.yaml`. With no disk left it ends as before. A refusal at the start still refuses the start.
- No API here (TASK-156).
<!-- SECTION:PLAN:END -->
