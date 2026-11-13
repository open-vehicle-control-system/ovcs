---
id: TASK-128
title: Track the simulated vehicle's pose
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
dependencies: []
ordinal: 88000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`SimulatorCore.Vehicle` integrates its planar pose (x, y, heading) and yaw rate from its speed and steering angle with a kinematic bicycle model, in REP-103 axes, so scenarios can assert on where the car went and GUI simulators can show it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Straight, constant-curvature and reverse motion integrate to their closed-form pose, tested
<!-- AC:END -->
