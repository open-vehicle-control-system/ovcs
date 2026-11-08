---
id: TASK-37
title: Restrict VMS /api/actions to declared dashboard actions
status: Done
assignee: []
created_date: '2026-11-08 10:42'
updated_date: '2026-11-08 12:09'
labels:
  - P37
  - ovcs
milestone: m-6
dependencies: []
ordinal: 37000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 POST /api/actions on the VMS calls only module/action pairs an action row of the dashboard declares
- [x] #2 Any other request answers 404 without creating an atom
- [x] #3 Every action row of the reference vehicles stays callable
<!-- AC:END -->
