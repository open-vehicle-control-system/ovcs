---
id: TASK-182
title: List the vision dashboard's exporters by name
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-18T10:50:00Z'
labels:
  - vision
  - dashboard
dependencies: []
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The vision dashboard's menu lists the unit's exporters in the order the API sends them, the order of the composer's `exporters`, which differs from one vehicle to the next. The menu lists them in alphabetical order of their names instead. The exporters store sorts them as it loads them, so the menu and the statuses it reads by position share one order.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The menu lists the exporters in alphabetical order of their names, whatever order the API sends them in
<!-- AC:END -->
