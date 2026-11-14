---
id: TASK-90
title: Expire ROS samples before the first consumer tick
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

A new ROS sample can arrive after an outage and expire before the consumer's next loop. The freshness tracker still considers the outage reported, so it returns `:unchanged`. Both throttle consumers keep the expired command until another sample arrives.

## Acceptance Criteria

- [x] A sample that expires before its first check reports stale once, even after an earlier outage.
- [x] Repeated frames do not extend the deadline or repeat outage reports.
- [x] Both actuator throttle and velocity consumers emit zero for this case and recover on fresh input.
- [x] Core formatting, compilation, lint and tests pass.

## Design

Keep expiry decisions in the pure freshness tracker. Mark a newly observed sequence as unreported so its expiry is delivered even if no intervening check observed it fresh. Checking staleness separately in every consumer would duplicate this invariant and leave other consumers exposed. The wire protocol and existing deadlines remain unchanged.

## Validation

All three new regressions failed before the fix. Formatting, compilation with warnings as errors, strict Credo and the complete core suite pass (260 tests).
