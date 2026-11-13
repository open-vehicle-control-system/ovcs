---
id: TASK-114
title: Echo pin requests in the simulated generic controller
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-13 08:57'
labels:
  - simulator
dependencies: []
ordinal: 74000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
SimulatorCore.SimulatedComponents.OVCS.GenericController reads no frame and reports every digital pin false. The VMS checks a relay by the pin status the controller reports, not by its own request (VmsCore.Components.OVCS.GenericController), so no relay-gated readiness can pass in simulation: OVCS1's contactors, inverter and iBooster each wait on one.

Options:
1. Each simulated component that sits behind a relay reports its own pin.
2. The simulated generic controller reads its digital pin request frame and reports the requested pins as its pin status, as the board does once its relays switch.

Chosen: 2. One component owns the board's pins, every instance has its own frames by name, and a stuck relay can later be injected in one place.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The simulated generic controller reads its digital pin request frame and reports the requested digital pins in its pin status, keeping its analog readings
- [x] #2 Several instances run side by side, each with its own frames (OVCS1 has front, controls and rear controllers)
- [x] #3 The OVCS Mini's simulated bridge receives the request frame, and the Mini still drives in Gazebo as before
- [x] #4 simulator/core tests pass, with format, credo and dialyzer
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
The pin status is re-emitted only when a request changes a pin; Cantastic keeps sending the merged data at the frame's 10 Hz. The OVCS Mini disables every digital pin, so its echo reports what it did before. Gazebo drive check, OVCS Mini, 0.5 m/s for 8 s, two runs: 3.83 m of 4.00 m commanded, /odom 0.0 % from ground truth, as on main (3.80–3.84 m).
<!-- SECTION:NOTES:END -->
