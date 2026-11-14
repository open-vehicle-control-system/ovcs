---
id: TASK-99
title: Review VMS correctness and reliability
status: In Progress
assignee: [Codex]
created_date: '2026-11-13 00:45'
labels: [vms, review]
dependencies: []
---

Review VMS core, API, dashboard, firmware and vehicle control wiring. Record confirmed defects, focused fixes and remaining risks without changing vision or deploying hardware.

## Acceptance Criteria

- [x] Review report links evidence, priorities and follow-up tasks.
- [x] Focused implementation PRs include regression tests and local validation.
- [x] Combined fixes pass core, API, dashboard and firmware host checks.
- [ ] Draft PRs receive independent review and are merged.

## Design

Trace inputs through control decisions and CAN outputs, reproduce failure modes locally, and keep each implementation independently reviewable. Separate verified code behavior from board-level assumptions.
