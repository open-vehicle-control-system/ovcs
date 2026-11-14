---
id: TASK-155
title: Fill USB disks in order with recordings
status: To Do
assignee: []
created_date: '2026-11-14T19:13:00Z'
labels:
  - vision
dependencies: []
ordinal: 108000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PR 4 of the ROS 2 bag exporter, after #352: ext4 USB disks found by UUID, mounted, ordered and turned on or off in a VisionCore.Models model, filled one after another, ejected.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A recording continues on the next disk when one fills or is pulled out
- [ ] #2 The order survives unplugging and a reboot
<!-- AC:END -->
