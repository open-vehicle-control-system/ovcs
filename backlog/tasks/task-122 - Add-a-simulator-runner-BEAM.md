---
id: TASK-122
title: Add a simulator runner BEAM
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
dependencies: []
ordinal: 82000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A host-only Mix project, `simulator/runner`, that runs `SimulatorCore.Hardware` for the vehicle `VEHICLE` names, with no ROS. The vehicle describes its simulated hardware in an optional `OvcsVehicle` callback, `simulator/0`: the motion model's parameters, the simulated components, and the CAN topology and host mapping of the frames they read and emit. With no world to measure the wheels, the motion is the model's own (`SimulatorCore.Vehicle.step/4` without a measurement). The runner logs a line once its emitters run, for the CLI to wait on.

The OVCS Mini gets a `simulator/0` with the components its `ros` bridge runs under `OVCS_SIM`; that path stays until TASK-130.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `VEHICLE=OvcsMini mix run --no-halt` in `simulator/runner` runs the Mini's simulated hardware on vcan with no ROS
- [ ] #2 `OvcsVehicle` documents `simulator/0`, and `ovcs new` vehicles get a commented example
- [ ] #3 Tests cover reading a vehicle's `simulator/0` and the runner starting its components
<!-- AC:END -->
