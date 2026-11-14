---
id: TASK-145
title: Harden the vision code in systematic passes
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-14T00:18:00Z'
updated_date: '2026-11-14T04:56:00Z'
labels:
  - vision
dependencies: []
ordinal: 101000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Passes over vision/core, vision/api, vision/dashboard and vision/firmware, one focus each: crash paths and supervision, duplication and dead code, structure and naming against CODE_STYLING.md, test gaps. Each finding is verified against the code before it is changed, a bug gets a failing test first, and a refactoring preserves behaviour.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each pass's confirmed findings are fixed or listed as tasks
- [ ] #2 Every project's checks pass and the pipelines keep their rates on a unit
<!-- AC:END -->
