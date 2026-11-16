---
id: TASK-121
title: Run vehicles headless in a simulator runner
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
updated_date: '2026-11-15 17:19'
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
1. **One dynamics model, driven by actuator efforts.** Exactly one model integrates the car: two models of one body drift apart, and correcting one from the other makes it oscillate. The simulated actuators send efforts (drive torque at the wheels, brake torque, steering angle, driveline inertia), the model moves the car in its world, and the simulated sensors report each wheel's spin and the IMU from its state, as on the vehicle. Options: OVCS owns the motion and a GUI simulator only shows the pose (headless and GUI runs alike, but no rollover, wheel lift, slip or collision, and wheels that never turn without moving the car); or the GUI simulator's physics engine owns it, against its own world geometry. Chosen: the GUI simulator, Godot and Gazebo alike, because the VMS must be tested against a world that contradicts its commands: a wall stops the car while the VMS still commands torque, a flipped car's wheels spin in the air. `SimulatorCore.Vehicle` stays as a flat-ground model for runs with no GUI simulator, documented as lower fidelity. The simulation runs in real time, as the VMS does: runs are not bit-exact, and scenarios assert with tolerances.
2. **The simulated hardware runs in its own BEAM, started before the VMS.** Options: the CLI waits for every bridge before starting the VMS (small, keeps simulation tied to ROS); or a simulator BEAM outside the ROS bridge. Chosen: its own BEAM, as the parts power up with the car before the VMS boots. It needs no ROS, and it can stand in for only some parts while the rest are real.
3. **A scenario performs the operator's actions.** The ignition key, the radio and the VMS reset (`reset_status`, through `POST /api/actions`, the dashboard's path) are scenario steps, not scripts inside simulated components. A scenario recovers a latched `FAILURE` as an operator does.
4. **Assertions read what the VMS sends on CAN** (`vms_status`: status and ready to drive; actuator requests), so the VMS stays a black box and the same scenarios run against real hardware.

Sequence, one PR each: TASK-122 runner, TASK-123 CLI start order, TASK-124 scenarios, TASK-125 fault injection, TASK-126 CI, TASK-127 OVCS1 headless, TASK-128 pose, TASK-172 actuator efforts, TASK-129 GUI simulator link, TASK-130 Gazebo by actuator efforts, TASK-131 Cantastic pin.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 TASK-122 to TASK-131 and TASK-172 are done
- [ ] #2 The OVCS Mini and OVCS1 boot, reach ready to drive and drive in a headless scenario run in CI, with no manual step
- [ ] #3 A GUI simulator moves the car from the efforts the runner's simulated actuators send, and vision runs on its cameras
<!-- AC:END -->
