---
id: TASK-180
title: Declare OVCS1's simulated hardware
status: Done
assignee:
  - '@claude'
created_date: '2026-11-13 23:19'
updated_date: '2026-11-17 18:17'
labels:
  - simulator
  - ovcs1
dependencies:
  - TASK-122
  - TASK-140
ordinal: 95000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1 declares no `simulator/0`, so the simulator runner cannot run it. Its simulated hardware: the front, controls and rear generic controllers, the Polo 9N ABS and ignition lock, the Leaf AZE0 inverter, the iBooster Gen2, the steering column and the radio, with a topology covering the frames they read and emit on its buses.

The controllers, pins, networks and radio channels come from `Ovcs1.Vms.Composer.wiring/0`, which the VMS components also start from, so the two cannot disagree. The reduction ratio is the Polo 02R gearbox's first gear times its final drive: the Leaf motor drives the gearbox through a coupling, with no Leaf reducer, and the simulation holds first gear. The physical parameters OVCS1 has no measurement for (mass, pack voltage, steering ratio, steps per column degree, column end stop, iBooster rod speed and full-travel deceleration) are set from the parts' public specifications or estimated, and listed in the vehicle's README.

The radio stays at `:manual`, and the key turns to start, then on, once the VMS is up. Driving, steering and braking under `:ros` from a scenario remain TASK-127. The Orion BMS2 and the EVPT charger are not simulated: they do not gate `vms_status` or ready to drive.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Ovcs1.simulator/0 declares the simulated hardware, with its controllers, pins, networks and radio channels read from Ovcs1.Vms.Composer.wiring/0
- [x] #2 OVCS1's simulator topology loads, declares every frame its simulated components read and emit, and maps its networks on the VMS's interfaces, tested
- [x] #3 With the runner started first, OVCS1 boots to vms_status OK and ready to drive with no manual step
- [x] #4 The vehicle's README lists the simulated parameters and which are estimates
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
`Ovcs1.Vms.Composer.wiring/0` holds the networks, controllers, pins and radio channels; the VMS children merge it into their options, so `children/0` returns the same term as before, and `Ovcs1.Simulator` reads it. The generic controllers come from `generic_controllers/0`. The vehicle lists `simulator_core`, compile-only, on the targets the `ros` bridge builds it for, as the OVCS Mini does.

Live check on vcan0 to vcan4, `./ovcs run ovcs1 --simulate --no-addons`, 90 s: the key turned to start 1 s after the VMS's first `vms_status` and back to on 1 s later; the VMS reported ready to drive 2 s after its first frame, then `OK` and ready to drive in 879 of 889 frames, the 10 others its 1 s boot reset. The runner cannot decode `brake_request` and `vms_torque_request`, which carry checksums, and logs each one dropped: the simulated iBooster and inverter see no request until TASK-131, which driving needs (TASK-127), not the boot.
<!-- SECTION:NOTES:END -->
