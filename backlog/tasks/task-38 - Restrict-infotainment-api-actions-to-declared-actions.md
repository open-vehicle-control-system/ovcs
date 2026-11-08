---
id: TASK-38
title: Restrict infotainment /api/actions to declared actions
status: Done
assignee: []
created_date: '2026-11-08 10:42'
labels:
  - P38
  - ovcs
milestone: m-6
dependencies:
  - TASK-37
ordinal: 38000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
InfotainmentApiWeb.Api.ActionsController turned the request's module string into an atom and called its trigger_action/2, so any module loaded in the infotainment firmware could be called. Only a module and action pair a block's actions declares is called, as on the VMS, and an action error answers 422.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A module and action pair no block's actions declares answers 404 without creating an atom
- [x] #2 An action returning {:error, reason} answers 422 with the reason
<!-- AC:END -->
