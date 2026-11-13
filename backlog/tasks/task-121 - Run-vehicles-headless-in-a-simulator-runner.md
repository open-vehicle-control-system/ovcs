---
id: TASK-121
title: Run vehicles headless in a simulator runner
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
dependencies: []
ordinal: 81000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Goals: simulate a vehicle headless, inject faults and check that the VMS reacts as expected; and let any GUI simulator (Gazebo, Godot, CARLA) show the car moving under the OVCS stack, with vision tested on its cameras.

Today the simulated hardware (`SimulatorCore.Hardware`) runs inside the `ros` bridge, which `./ovcs run` starts at the same moment as the VMS. OVCS1's VMS latches `FAILURE` when its generic controllers are not alive and OK at the end of its 5 s boot period, and they answer later than that. The latch is deliberate, and TASK-20 makes it stricter (no boot grace, re-arming only by an explicit reset), so the fix belongs to the simulation, not the VMS. Simulation also needs ROS and a world that measures the wheels, and nothing injects a fault or checks a reaction.

Decisions:
1. **OVCS owns the motion.** `SimulatorCore.Vehicle` moves the car. A GUI simulator only shows its pose and returns camera images. Options: the GUI's physics moves the car and reports wheel turns back, as the Gazebo world does now (realistic dynamics, but headless runs need stand-in physics and results depend on the GUI); or OVCS moves it (deterministic, repeatable fault tests). Chosen: OVCS.
2. **The simulated hardware runs in its own BEAM, started before the VMS.** Options: the CLI waits for every bridge before starting the VMS (small, keeps simulation tied to ROS); or a simulator BEAM outside the ROS bridge. Chosen: its own BEAM, as the parts power up with the car before the VMS boots. It needs no ROS, and it can stand in for only some parts while the rest are real.
3. **A scenario performs the operator's actions.** The ignition key, the radio and the VMS reset (`reset_status`, through `POST /api/actions`, the dashboard's path) are scenario steps, not scripts inside simulated components. A scenario recovers a latched `FAILURE` as an operator does.
4. **Assertions read what the VMS sends on CAN** (`vms_status`: status and ready to drive; actuator requests), so the VMS stays a black box and the same scenarios run against real hardware.

Sequence, one PR each: TASK-122 runner, TASK-123 CLI start order, TASK-124 scenarios, TASK-125 fault injection, TASK-126 CI, TASK-127 OVCS1 headless, TASK-128 pose, TASK-129 GUI link in pose mode, TASK-130 Gazebo as a viewer, TASK-131 Cantastic pin.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 TASK-122 to TASK-131 are done
- [ ] #2 The OVCS Mini and OVCS1 boot, reach ready to drive and drive in a headless scenario run in CI, with no manual step
- [ ] #3 A GUI simulator shows the car the runner moves, and vision runs on its cameras
<!-- AC:END -->
