---
id: TASK-127
title: Run OVCS1 headless
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
updated_date: '2026-11-13 22:55'
labels:
  - simulator
  - ovcs1
dependencies:
  - TASK-122
  - TASK-124
  - TASK-131
  - TASK-140
ordinal: 87000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1's `simulator/0`: three generic controllers with their pin echo (TASK-114), the Polo 9N ABS (TASK-116), the Leaf AZE0 inverter (TASK-117), the iBooster Gen2 (TASK-118), the steering column (TASK-119) and the radio, with its simulated topology. The ignition key is a scenario input. Unmeasured parameters (steps per column degree, steering ratio, column end stop, iBooster rod speed and full-travel deceleration, pack voltage, mass) are set from the vehicle's documentation where it has them, and listed in the vehicle's docs where not.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A scenario boots OVCS1 to ready to drive with no manual step, then drives, steers and brakes it under `:ros`
- [ ] #2 OVCS1's simulated topology loads, tested
<!-- AC:END -->
