---
id: TASK-22
title: Add a rolling counter to the radio control frames
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
updated_date: '2026-11-08 11:33'
labels:
  - P22
  - ovcs
milestone: m-3
dependencies:
  - TASK-50
ordinal: 22000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
0x2A0/0x2A1 carry four 16-bit channels and no counter, so the VMS cannot tell a frozen bridge from a steady stick. Add a rolling counter (12-bit channels or an extra frame) that the bridge increments only when new RC data arrives, and a CRC. The VMS does not use them yet.
<!-- SECTION:DESCRIPTION:END -->
