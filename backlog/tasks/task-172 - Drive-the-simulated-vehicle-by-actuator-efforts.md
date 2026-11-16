---
id: TASK-172
title: Drive the simulated vehicle by actuator efforts
status: To Do
assignee: []
created_date: '2026-11-15 17:19'
labels:
  - simulator
dependencies:
  - TASK-122
ordinal: 104000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The simulated actuators act on `SimulatorCore.Vehicle` through accelerations, a speed and a steering angle, the vehicle integrates them on flat ground with no slip, and a world is handed a target speed. Under TASK-121's decision 1 the world's dynamics model owns the car, driven by actuator efforts, and the simulated sensors measure its state.

- **Actuations become efforts.** The inverter and the VESC send drive torque at the driven axle (motor torque times the overall ratio) and the driveline's inertia there; the iBooster sends brake torque from its rod position; the steering column and the Traxxas servo send the front wheels' angle.
- **The world reports its state.** `SimulatorCore.World` takes the efforts each tick and gives back each wheel's angle, spin and contact, the body's motion and the IMU's acceleration.
- **Sensors read the world's state.** The ABS reports each wheel's speed, the VESC and the generic controller's pulse counter the driven wheels', from that state, so a wheel spinning in the air or stalled against a wall reads as it would on the vehicle.
- **`SimulatorCore.Vehicle` becomes the flat-ground world** for runs with no GUI simulator: mass, wheel radius, rolling resistance and brakes, no slip, no contact, documented as lower fidelity. Until TASK-130, the Gazebo world follows its speed.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each simulated actuator sends its effort, tested from the frames the VMS sends it
- [ ] #2 Each simulated sensor reports from the world's per-wheel state, tested with a wheel spinning without contact and a wheel stalled
- [ ] #3 The flat-ground world turns efforts into motion, tested against closed-form acceleration and braking
- [ ] #4 The OVCS Mini boots and drives under `./ovcs run --simulate`, and the Gazebo drive check still passes
<!-- AC:END -->
