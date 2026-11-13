---
id: TASK-104
title: Load the repository's credo comment checks
status: To Do
assignee: []
created_date: '2026-11-12 13:00'
labels:
  - tooling
dependencies: []
ordinal: 83000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`mix credo --strict` in `vision/core` warns that `Ovcs.Credo.Comments.parse/1` is undefined while the checks under `.credo/checks/` load, so the repository's comment rules (no history, no session narration) may not run at all, and comments are only checked by hand.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The custom comment checks run in every Elixir project's `mix credo --strict`, with no undefined-function warning
- [ ] #2 A comment that narrates history fails credo in a test fixture
<!-- AC:END -->
