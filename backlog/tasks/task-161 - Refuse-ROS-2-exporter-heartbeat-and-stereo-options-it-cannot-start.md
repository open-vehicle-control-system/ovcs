---
id: TASK-161
title: Refuse ROS 2 exporter heartbeat and stereo options it cannot start
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T05:53:00Z'
updated_date: '2026-11-15T05:55:00Z'
labels:
  - vision
dependencies: []
ordinal: 110000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`VisionCore.Ros2.ZenohExporter.check/1` checks the link, `stereo:`, `cameras:`, `detections:` and `segmentation:`, but not `heartbeat:`, nor the shape of `stereo:`. A `heartbeat:` that is no keyword list (`true`) or whose `:interval_ms` is no positive integer, and a `stereo:` that is no keyword list (`true`), pass the check and raise in `init/1`, so the exporter restarts against its budget instead of being refused at start with the reason logged. A `heartbeat:` option it does not take (`interval: 500`) is ignored silently.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 check/1 refuses a heartbeat: that is no keyword list, false included, saying so
- [ ] #2 check/1 refuses a heartbeat: option other than :interval_ms, naming it
- [ ] #3 check/1 refuses an :interval_ms that is no positive integer, naming the value
- [ ] #4 check/1 still accepts heartbeat: [] and heartbeat: [interval_ms: <positive integer>], and the vehicles composers pass it
- [ ] #5 check/1 refuses a stereo: that is no keyword list, saying so, which raised in init/1
<!-- AC:END -->
