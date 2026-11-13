---
id: TASK-126
title: Run the simulator scenarios in CI
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
  - ci
dependencies:
  - TASK-124
ordinal: 86000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A CI job creates vcan interfaces and runs every vehicle's scenarios headless, failing the build on a failed scenario.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The OVCS Mini's scenarios run on every PR
- [ ] #2 A failed scenario fails the job and shows its failed step
<!-- AC:END -->
