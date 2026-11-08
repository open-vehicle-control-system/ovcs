---
id: TASK-33
title: Watch bms_status_3 and publish unknown when stale
status: To Do
assignee: []
created_date: '2026-11-08 10:42'
labels:
  - P33
  - ovcs
milestone: m-5
dependencies:
  - TASK-30
ordinal: 33000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Bms2 publishes nil flags when stale and on restart, so an unknown error is never read as healthy.
<!-- SECTION:DESCRIPTION:END -->
