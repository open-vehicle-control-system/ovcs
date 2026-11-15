---
id: TASK-167
title: Rename the vision unit's debug exporter to Snapshot
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T11:19:00Z'
labels:
  - vision
dependencies: []
ordinal: 111000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The vision unit's debug exporter, VisionCore.Debug.Exporter, records a short burst of stereo pairs with the unit's state as one zip, for tuning and bug reports. "Debug" says neither what it records nor what a tuner does with it, and its action "export" repeats the exporter's own kind. Rename it Snapshot: the exporter VisionCore.Snapshot.Exporter, listed as snapshot, "Snapshot", with the action take; the zip VisionCore.Snapshot, named vision-snapshot-<hostname>-<time>.zip; the rest of the VisionCore.Debug namespace (Png, Compare) and mix vision_core.compare_exports move with it. The API serves it at /api/exporters/snapshot. No alias for the old id: nothing outside this repository reads it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 VisionCore.Snapshot.Exporter is listed by VisionCore.Exporters as snapshot, "Snapshot", with one action take, labelled "Take snapshot", that answers a zip named vision-snapshot-<hostname>-<YYYYMMDDTHHMMSSZ>.zip
- [x] #2 No VisionCore.Debug module remains: the zip is VisionCore.Snapshot, and Png and Compare live under VisionCore.Snapshot
- [x] #3 mix vision_core.compare_snapshots compares two snapshots; mix vision_core.compare_exports is gone
- [x] #4 The OVCS Mini's and OVCS1's composers list VisionCore.Snapshot.Exporter
- [x] #5 The vision guides and the API reference name the snapshot exporter, its take action and POST /api/exporters/snapshot/actions/take
<!-- AC:END -->
