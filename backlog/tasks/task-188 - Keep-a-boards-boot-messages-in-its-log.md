---
id: TASK-188
title: Keep a board's boot messages in its log
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T13:50:00Z'
labels:
  - firmware
  - observability
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A board's log is RingLogger's buffer, 1024 entries by default. The VMS, bridge and infotainment firmwares log at debug: on the OVCS Mini's ROS bridge, Zenoh's per-message debug lines filled the buffer, 1023 of its 1024 entries, minutes after boot. The vision unit logs at info, but its pipelines' rate lines filled the Mini's within minutes too. Whatever went wrong at boot was gone before anyone looked.

Every firmware logs at info and keeps 8192 entries.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The VMS, bridge, infotainment and vision firmwares log at info into a RingLogger buffer of 8192 entries
- [x] #2 On the OVCS Mini, each board's buffer still holds its boot messages a few minutes after boot
<!-- AC:END -->
