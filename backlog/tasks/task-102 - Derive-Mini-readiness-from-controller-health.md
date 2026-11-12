---
id: TASK-102
title: Derive Mini readiness from controller health
status: To Do
priority: high
labels: [vms, review]
dependencies: []
---

OvcsMini.Vms initializes ready_to_drive to true and its readiness function is a no-op. After the boot period with the main controller absent, the local callback emits FAILURE and ready_to_drive=true together.

## Acceptance Criteria

- [ ] Readiness starts false and requires confirmed controller health.
- [ ] A controller fault or unknown health withdraws readiness in the same tick.
- [ ] Boot, reset and fault recovery have explicit tests and re-arm semantics.

## Design

Introduce a pure vehicle readiness decision and compute it from current status before broadcasting. Validate the resulting motor/steering interlock on the Mini bench.
