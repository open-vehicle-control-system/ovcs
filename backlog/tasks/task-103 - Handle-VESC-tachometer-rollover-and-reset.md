---
id: TASK-103
title: Handle VESC tachometer rollover and reset
status: To Do
priority: medium
labels: [vms, review]
dependencies: []
---

Tachometer differences use ordinary subtraction on a signed 32-bit counter. Moving from 2147483646 to -2147483646 in 100 ms at two pole pairs reports -214748364600 rpm instead of 200 rpm. The cumulative revolution path also jumps.

## Acceptance Criteria

- [ ] Both signed rollover directions produce the correct small delta.
- [ ] A device reset invalidates or explicitly rebases speed and distance.
- [ ] Tests cover speed and the emitted distance counter across discontinuities.

## Design

Give one pure counter tracker ownership of unwrap and reset handling. Use vehicle-specific plausibility limits; fixing only the speed difference leaves odometry inconsistent.
