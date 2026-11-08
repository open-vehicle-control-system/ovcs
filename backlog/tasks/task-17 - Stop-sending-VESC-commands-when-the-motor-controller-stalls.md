---
id: TASK-17
title: Stop sending VESC commands when the motor controller stalls
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P17
  - ovcs
milestone: m-2
dependencies:
  - TASK-9
ordinal: 17000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Stop emitting on staleness so the VESC's own CAN timeout applies one configured safe state, instead of per-frame zeros that brake or coast.
<!-- SECTION:DESCRIPTION:END -->
