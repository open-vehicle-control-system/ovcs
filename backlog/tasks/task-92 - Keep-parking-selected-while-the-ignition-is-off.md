---
id: TASK-92
title: Keep parking selected while the ignition is off
status: In Progress
assignee:
  - Codex
created_date: '2026-11-12 23:00'
labels:
  - vms
  - safety
dependencies: []
---

## Description

The ignition-off rule only runs when the selected gear is not parking. A subsequent tick can select drive, reverse or neutral from a retained request while ready-to-drive remains true. With the ignition still off, the next tick returns to parking, and selection oscillates.

## Acceptance Criteria

- [ ] Parking remains selected across repeated ticks with the ignition off, for every requested gear.
- [ ] An active gear returns to parking with the ignition off even when readiness remains true.
- [ ] Turning the ignition on permits the existing normal gear-selection rules.
- [ ] Core checks pass.

## Design

Move the existing selection function to a pure module without changing behavior. Then make the ignition-off rule cover parking itself, preventing later conditions from accepting a request. Preserve the existing policy of selecting parking when contact is off; input freshness and alternative stopping policies remain separate work.
