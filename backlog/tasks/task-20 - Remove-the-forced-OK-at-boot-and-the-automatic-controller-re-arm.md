---
id: TASK-20
title: Remove the forced OK at boot and the automatic controller re-arm
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P20
  - ovcs
milestone: m-2
dependencies:
  - TASK-19
ordinal: 20000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Drop the 5 s booting OK and the boot reset timer; re-arming needs the explicit reset action. Flip the tests that lock in the old behaviour.
<!-- SECTION:DESCRIPTION:END -->
