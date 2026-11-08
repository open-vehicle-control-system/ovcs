---
id: TASK-11
title: Tie vms_status to the vehicle's control-loop tick
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P11
  - ovcs
milestone: m-2
dependencies:
  - TASK-10
ordinal: 11000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Status records when the vehicle's :vms_status message last arrived and emits FAILURE once it is older than the deadline.
<!-- SECTION:DESCRIPTION:END -->
