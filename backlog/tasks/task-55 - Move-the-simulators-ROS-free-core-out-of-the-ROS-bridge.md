---
id: TASK-55
title: Move the simulator's ROS-free core out of the ROS bridge
status: Done
assignee: []
created_date: '2026-11-08 19:06'
labels:
  - simulator
milestone: m-1
dependencies: []
ordinal: 51000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
RosBridge.Simulator holds simulated hardware a VMS drives over CAN, but only a vehicle with a ROS bridge can run it. The simulated components and the motion model they act on use no ROS: move SimulatedComponent, the simulated components and Vehicle to a new simulator/core project, under SimulatorCore, with no change in behaviour. The loop that runs them against the VMS, RosBridge.Simulator.Hardware, stays in the ROS bridge.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SimulatorCore.SimulatedComponent, the simulated components and SimulatorCore.Vehicle live in simulator/core with their tests
- [x] #2 ros_bridge and simulator/core together run the same 172 tests as ros_bridge did, and OVCS Mini's tests pass
- [x] #3 CI and the Firmware workflow build and test simulator/core
<!-- AC:END -->
