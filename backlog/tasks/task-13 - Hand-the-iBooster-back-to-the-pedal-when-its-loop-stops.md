---
id: TASK-13
title: Hand the iBooster back to the pedal when its loop stops
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P13
  - ovcs
milestone: m-2
dependencies:
  - TASK-9
  - TASK-12
ordinal: 13000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Brake request expires to the safe values. A stale braking_system_ready_to_drive reads as not ready, so propulsion stops too. Tests in P12's file, at the boundary; a test fails if the per-tick refresh is removed.
<!-- SECTION:DESCRIPTION:END -->
