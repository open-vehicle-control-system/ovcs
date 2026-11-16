---
id: TASK-130
title: Drive Gazebo by actuator efforts through the simulator runner
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
updated_date: '2026-11-15 17:19'
labels:
  - simulator
  - ros
dependencies:
  - TASK-122
  - TASK-172
ordinal: 90000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Gazebo behaves as the other GUI simulators (TASK-121, decision 1): its physics owns the car, driven by actuator efforts. Today `RosBridge.Simulator.World` publishes a target speed and yaw rate that Gazebo's `AckermannSteering` follows in velocity mode, and OVCS's motion model integrates the wheel turns it reads back: two models of one car, and wheels forced to the commanded speed against a wall.

The vehicle's Gazebo model takes the drive torque on its driven wheel joints, the steering angle through position control of its steering joints, and the brake torque on every wheel joint, with no `AckermannSteering`. The world sends the runner's efforts and reads each wheel joint's angle and speed, the contacts and the IMU, which the simulated sensors report. It runs from the simulator runner, and the `ros` bridge stops hosting simulated hardware (`:simulated_hardware`, `OVCS_SIM`), leaving one simulation path.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The OVCS Mini drives in Gazebo through the runner from its simulated actuators' efforts, with its lidar and cameras
- [ ] #2 The ros bridge no longer hosts simulated hardware, and its docs say so
- [ ] #3 The Gazebo drive check passes against the efforts model, its distance covered within tolerance
<!-- AC:END -->
