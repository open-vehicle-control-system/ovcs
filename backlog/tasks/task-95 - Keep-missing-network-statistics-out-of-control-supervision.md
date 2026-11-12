---
id: TASK-95
title: Keep missing network statistics out of control supervision
status: In Progress
assignee:
  - Codex
created_date: '2026-11-13 00:24'
labels:
  - vms
  - reliability
dependencies: []
---

## Description

Polling network statistics crashes `VmsCore.NetworkInterfaces` when a configured interface disappears. This diagnostics worker shares the vehicle supervisor restart budget. Empty statistics also crash the dashboard counter renderer.

## Acceptance Criteria

- [x] A missing interface returns unavailable statistics without raising.
- [x] Available interfaces remain visible alongside unavailable interfaces.
- [x] The dashboard shows unavailable statistics and recovers on the next successful update.
- [x] Core tests, formatting, compilation, strict Credo, dashboard tests and build pass.

## Design

Treat missing `ip`, command failure, and unexpected JSON as an unavailable snapshot represented by the existing empty statistics map. Do not cache a previous healthy snapshot. Render an explicit unavailable state and omit counters until they arrive. Keep operating-system errors out of the control supervisor's restart budget.
