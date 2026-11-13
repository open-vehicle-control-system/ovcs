---
id: TASK-135
title: Serve exporter status and CPU load from one place in the vision API
status: To Do
assignee: []
created_date: '2026-11-13T16:28:00Z'
labels: []
dependencies:
  - TASK-133
ordinal: 92000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two figures have two copies. An exporter's status is in GET /api/exporters and in the status channel's exporters; the dashboard picks the live one over the listed one (exporterStatus). The CPU load is in GET /api/board and in the status channel, measured separately over different windows; the vision dashboard shows the board's, through the shared @ovcs/ui board, and never reads the channel's.

Design: GET /api/exporters is the static listing (name, module, outputs, actions) without status; the status channel carries every exporter's status, the API's own entry included, which only the controller adds today. The status channel's payload drops cpuPercent; VisionCore.Status keeps measuring it for the debug export. OvcsVehicle.BoardStatus is shared with the VMS and stays as it is.

Options considered: dropping the channel's exporter statuses and polling GET /api/exporters (slower, and each poll asks every exporter); dropping cpuPercent from the board (changes the shared library and the VMS).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 GET /api/exporters lists no status
- [ ] #2 The status channel reports the API's own exporter entry
- [ ] #3 The status channel's payload has no cpuPercent
- [ ] #4 The dashboard shows each exporter's status from the status channel alone
- [ ] #5 The docs and vision/api/README.md match
<!-- AC:END -->
