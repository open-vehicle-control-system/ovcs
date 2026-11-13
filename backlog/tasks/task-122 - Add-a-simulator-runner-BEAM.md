---
id: TASK-122
title: Add a simulator runner BEAM
status: Done
assignee:
  - '@claude'
created_date: '2026-11-13 14:00'
updated_date: '2026-11-13 22:03'
labels:
  - simulator
dependencies: []
ordinal: 82000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A host-only Mix project, `simulator/runner`, that runs `SimulatorCore.Hardware` for the vehicle `VEHICLE` names, with no ROS. The vehicle describes its simulated hardware in an optional `OvcsVehicle` callback, `simulator/0`: the motion model's parameters, the simulated components, and the CAN topology and host mapping of the frames they read and emit. With no world to measure the wheels, the motion is the model's own (`SimulatorCore.Vehicle.step/4` without a measurement). The runner logs a line once its emitters run, for the CLI to wait on.

The OVCS Mini gets a `simulator/0` with the components its `ros` bridge runs under `OVCS_SIM`; that path stays until TASK-130.

Running with no world, options:
1. `SimulatorCore.Hardware`'s `:world` becomes optional: without one, nothing outside moves the vehicle and its motion is `SimulatorCore.Vehicle`'s own.
2. A world module that does nothing, passed where no world is wanted.

Chosen: 1. Having no world is the runner's normal case once OVCS owns the motion (TASK-121), not a stand-in to configure, and the loop already follows its own motion when a world reports nothing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `VEHICLE=OvcsMini mix run --no-halt` in `simulator/runner` runs the Mini's simulated hardware on vcan with no ROS
- [x] #2 `OvcsVehicle` documents `simulator/0`, and `ovcs new` vehicles get a commented example
- [x] #3 Tests cover reading a vehicle's `simulator/0` and the runner starting its components
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The runner prints `OVCS simulator ready` on standard output once `SimulatorCore.Hardware` has started every simulated component and configured its emitters. It depends on `ovcs_can` at runtime, since vehicle topologies import their frames from it.

The OVCS Mini's `vehicles/ovcs_mini/priv/can/simulator.yml` declares the frames of its four simulated components, the radio's `vms_status` included; a test checks it declares every frame each component reads and emits. It also receives `main_controller_digital_pin_request`, which the simulated generic controller reads once it echoes its pins (TASK-114). `priv/can/bridges/ros_simulated_components.yml` holds the same frames for the `ros` bridge until TASK-130 removes that path.

Live check on vcan0 and vcan1: the runner printed its ready line 3 s after start, with the radio, controller and VESC frames on the bus; the OVCS Mini's VMS, started after it, sent `vms_status` OK and ready to drive past its 5 s boot period.

The simulator guide (`docs/simulator/`, TASK-115) gets a section on the runner once it is on main.
<!-- SECTION:NOTES:END -->
