---
id: TASK-86
title: Show OVCS1's speed on its infotainment
status: In Progress
assignee:
  - '@mlainez'
created_date: '2026-11-11 15:31'
updated_date: '2026-11-11 15:32'
labels:
  - infotainment
  - ovcs1
dependencies: []
ordinal: 73000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Ovcs1.Infotainment handles drivetrain_status (0x60A), which carries the speed, and its topology declares it, but it never subscribes to it: the speed gauge stays at zero on the vehicle and in simulation.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 Ovcs1.Infotainment subscribes to drivetrain_status and its speed follows the VMS's
- [x] #2 Checked against the simulated OVCS1: the gauge follows the car's speed
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Checked against the simulated OVCS1: with the subscription, the infotainment's speed read 12.97 km/h while the VMS forwarded the simulated ABS's speed; without it, 0.
<!-- SECTION:NOTES:END -->
