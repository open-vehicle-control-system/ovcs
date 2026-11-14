---
id: TASK-93
title: Bound dashboard channel refresh intervals
status: In Progress
assignee:
  - Codex
created_date: '2026-11-12 23:00'
labels:
  - vms
  - api
dependencies: []
---

## Description

Both dashboard channels pass a client-supplied interval to the timer service. Zero can continuously enqueue work, including external interface-statistics commands; missing or invalid values crash channel setup. Validate the interval before joining or creating timers.

## Acceptance Criteria

- [x] Both channels reject missing, non-integer and out-of-range intervals with a join error.
- [x] Accepted intervals range from 50 to 60000 milliseconds, preserving the existing 70 ms metrics and 1000 ms interface refreshes.
- [x] Rejected joins schedule no work.
- [x] API formatting, compilation, lint and tests pass.

## Design

Use one pure interval parser shared by both channels. Reject invalid input rather than silently coercing it. A 50 ms floor bounds each subscription to 20 updates per second; a 60-second ceiling avoids invalid timer sizes. Connection limits and authentication remain separate work.

## Validation

Twenty invalid-input regressions failed before the fix. All 45 API tests, formatting, compilation with warnings as errors and strict Credo pass.
