---
id: TASK-149
title: Declare simulator core as a dependency of the vehicles that name it
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14 10:45'
labels:
  - simulator
dependencies: []
ordinal: 103000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The OVCS Mini's `simulator/0` names `simulator_core`'s simulated components, but the vehicle reaches that package only through `bridge_firmware` and `ros_bridge`. When the `ros` bridge stops hosting simulated hardware (TASK-130), that route goes away. The vehicle declares the dependency itself, compile-only and on the targets the `ros` bridge builds it for: the simulator runner runs the components, not the vehicle. The declaration moves from the top-level `OvcsMini` module to `OvcsMini.Simulator`, so the one module naming the simulator is apart from the VMS and bridge configuration.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `vehicles/ovcs_mini` lists `simulator_core` in its dependencies, and its checks pass
- [x] #2 The Mini's simulated hardware is declared in `OvcsMini.Simulator`, apart from its VMS and bridge configuration, and `simulator/0` returns what it did
<!-- AC:END -->
