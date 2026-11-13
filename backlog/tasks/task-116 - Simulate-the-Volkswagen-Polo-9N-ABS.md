---
id: TASK-116
title: Simulate the Volkswagen Polo 9N ABS
status: Done
assignee:
  - '@claude'
created_date: '2026-11-13 11:40'
updated_date: '2026-11-13 22:03'
labels:
  - simulator
  - ovcs1
dependencies: []
ordinal: 76000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1's VMS reads its speed from the Polo 9N ABS unit, on abs_status (0x5A0) and wheels_speed (0x4A0). With no simulated ABS the speed stays at zero, so every standstill check passes while the simulated vehicle moves.

A simulated component reports the vehicle's measured speed on both frames, in km/h and without direction, as the unit does. SimulatorCore.Vehicle has one speed, so every wheel reports it.

wheels_speed has no frequency, which Cantastic needs to emit a frame; it takes abs_status's 20 ms, as no Polo 9N rate is measured.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SimulatorCore.SimulatedComponents.Volkswagen.Polo9N.ABS reports the measured speed on abs_status and each wheel at it on wheels_speed, unsigned, in km/h
- [x] #2 Both frames emit with the shared definitions and read back through them as the VMS receives them, tested with no CAN bus
- [x] #3 simulator/core tests pass, with format, credo, dialyzer and warnings as errors
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
simulator/core's tests load ovcs_can's frame definitions through SimulatorCore.CanFrames (test/support), which builds a frame with the emitted definition and decodes it with the received one.
<!-- SECTION:NOTES:END -->
