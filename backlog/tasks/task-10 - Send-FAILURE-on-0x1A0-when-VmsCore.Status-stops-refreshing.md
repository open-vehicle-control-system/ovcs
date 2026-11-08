---
id: TASK-10
title: Send FAILURE on 0x1A0 when VmsCore.Status stops refreshing
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P10
  - ovcs
milestone: m-2
dependencies:
  - TASK-9
ordinal: 10000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Status stamps vms_status every tick; its builder falls back to FAILURE. Covers Status death, a Status stall and vms_core stopping, so generic controllers drop their outputs.
<!-- SECTION:DESCRIPTION:END -->
