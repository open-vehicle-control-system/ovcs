---
id: TASK-147
title: Run the simulator runner's checks in CI
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-14 10:30'
labels:
  - simulator
  - ci
dependencies: []
ordinal: 101000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Elixir job's project matrix lists `simulator/core` but not `simulator/runner`, so the runner's format, compile, credo, test and dialyzer checks never run in CI.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The Elixir job's matrix runs `simulator/runner`
<!-- AC:END -->
