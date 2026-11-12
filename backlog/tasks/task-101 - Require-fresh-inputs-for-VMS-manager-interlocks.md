---
id: TASK-101
title: Require fresh inputs for VMS manager interlocks
status: To Do
priority: high
labels: [vms, review]
dependencies: []
---

ControlLevel and Gear initialize a configured speed source to zero and retain speed, readiness and brake inputs without consumer-owned deadlines. A local probe selected radio control before any speed sample arrived.

## Acceptance Criteria

- [ ] A configured but unseen or expired speed source cannot prove standstill.
- [ ] Required readiness and brake inputs expire independently of their producers.
- [ ] Injected-time tests cover last-zero producer stalls, startup and recovery.

## Design

Extract the interlock decision into pure code with explicit sample ages. Set hardware-specific deadlines in the vehicle composer; preserve the intentional no-speed-source mode as an explicit configuration.
