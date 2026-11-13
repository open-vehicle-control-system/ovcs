---
id: TASK-118
title: Simulate the Bosch iBooster Gen2
status: Done
assignee:
  - '@claude'
created_date: '2026-11-13 12:00'
updated_date: '2026-11-13 22:03'
labels:
  - simulator
  - ovcs1
dependencies: []
ordinal: 78000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1's VMS powers the Bosch iBooster Gen2 through a generic controller relay, reads its status on ibooster_status (0x39D) and, under the radio control level, commands its rod through brake_request (0x38C). Its readiness needs the booster ready, and it reads an unpowered booster as the driver braking. With no simulated iBooster, OVCS1 cannot reach ready to drive in simulation, and nothing brakes.

A simulated component reports off until its power relay pin is requested, then ready with the brakes not applied. Under an external request its rod moves with the commanded flow rate's offset from its zero point, springs back without one, and decelerates the vehicle in proportion to its travel.

The shared 0x39D definition cannot be emitted: its signals are out of bit order and the rod position is split into three segments around them. Options for an emittable definition:
1. Reorder the shared definition: impossible while the rod position is one signal, since its segments interleave with the others.
2. A copy in each vehicle that simulates an iBooster.
3. A second definition next to the shared one in ovcs_can, under bosch/i_booster_gen2/simulated/, with the rod position as three fields.

Chosen: 3. The frame belongs to the component, not to a vehicle, and a test reads it back through the shared definition, so the two cannot drift apart.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 SimulatorCore.SimulatedComponents.Bosch.IBoosterGen2 reports off until its power relay pin is requested, then ready with the brakes not applied
- [x] #2 Under an external request its rod follows the flow rate within its travel, springs back without one, and decelerates the vehicle in proportion to its travel
- [x] #3 Its status emits with ovcs_can's simulated definition and reads back through the shared one as the VMS receives it, rod position included, tested with no CAN bus
- [x] #4 simulator/core tests pass, with format, credo, dialyzer and warnings as errors
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
brake_request carries a checksum signal, which the pinned Cantastic cannot decode on reception: the simulator receives no brake request until Cantastic's checksum decoding is merged and its pin bumped. The power relay and the status work without it.

The rod speed and the full-travel deceleration are options with no measured value. The rod position's high bit stays clear within the rod's travel (16.56 mm reads 1380 of 4096), so the tests cannot tell it from a stuck bit.
<!-- SECTION:NOTES:END -->
