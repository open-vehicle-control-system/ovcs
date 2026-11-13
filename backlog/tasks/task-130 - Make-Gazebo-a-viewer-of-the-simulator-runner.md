---
id: TASK-130
title: Make Gazebo a viewer of the simulator runner
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
  - ros
dependencies:
  - TASK-122
  - TASK-128
ordinal: 90000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Gazebo shows the pose the runner computes instead of moving the car and measuring its wheels, and the `ros` bridge stops running simulated hardware (`:simulated_hardware`, `OVCS_SIM`), leaving one simulation path.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The OVCS Mini drives in Gazebo through the runner, with its lidar and cameras
- [ ] #2 The ros bridge no longer hosts simulated hardware, and its docs say so
<!-- AC:END -->
