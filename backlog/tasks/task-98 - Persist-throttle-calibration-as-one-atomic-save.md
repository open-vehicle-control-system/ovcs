---
id: TASK-98
title: Persist throttle calibration as one atomic save
status: In Progress
assignee:
  - Codex
created_date: '2026-11-13 00:35'
labels:
  - vms
  - safety
  - persistence
dependencies: []
---

## Description

The pedal stores four calibration boundaries in separate transactions. An interrupted save can leave mixed generations. Loading the latest value orders only by a second-resolution timestamp, so a second calibration saved in the same second can reload the first calibration instead.

## Acceptance Criteria

- [ ] A failed boundary insert rolls back the complete calibration save.
- [ ] The latest complete calibration is selected even when timestamps tie.
- [ ] Both calibration stop paths use the same atomic persistence operation.
- [ ] Regression tests use a disposable real SQLite repository.
- [ ] Core tests, formatting, compilation and strict Credo pass.

## Design

First consolidate the duplicated save path without changing behavior. Then wrap all four boundary inserts in one Repo transaction and order reloads by descending primary key. Keep calibration plausibility and pedal output policy unchanged; track cross-checking remains TASK-26/27.
