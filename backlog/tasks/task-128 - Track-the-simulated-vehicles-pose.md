---
id: TASK-128
title: Track the simulated vehicle's pose
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 14:00'
labels:
  - simulator
dependencies: []
ordinal: 88000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`SimulatorCore.Vehicle` integrates its planar pose (x, y, yaw) from its speed and steering angle with a kinematic bicycle model, in REP-103 axes, so scenarios can assert on where the car went and GUI simulators can show it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Straight, constant-curvature and reverse motion integrate to their closed-form pose, tested
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The pose is the rear axle's centre. Each step moves it along the exact arc of the step's distance, the wheel turns times the circumference, so the commanded path and a world's measurement both drive it, signed as they are. The arc is taken along its chord, which stays exact for a curvature too small to change the yaw within a step. The yaw is REP-103's and stays within ±π. `Vehicle.curvature/1` is the one bicycle curvature; `RosBridge.Simulator.World.twist/1` derives Gazebo's yaw rate from it.
<!-- SECTION:NOTES:END -->
