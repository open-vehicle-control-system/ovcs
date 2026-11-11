---
id: TASK-90
title: Capture the IMX477 on the VENTUNO Q's Camera 2 in colour
status: To Do
assignee: []
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies: []
parent_task_id: TASK-87
ordinal: 69000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 3 of TASK-87: check that the IMX477's driver probes on Camera 2, then route it through `VisionCore.Camera.Camss` and capture it with `v4l2_capture` in its 2×2 binned mode, 2028 × 1520, demosaiced to colour. See TASK-87's Design.
<!-- SECTION:DESCRIPTION:END -->
