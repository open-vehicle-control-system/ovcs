---
id: TASK-39
title: Bind the infotainment API to loopback on the firmware
status: Done
assignee: []
created_date: '2026-11-08 10:42'
updated_date: '2026-11-08 12:02'
labels:
  - P39
  - ovcs
milestone: m-6
dependencies: []
ordinal: 39000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Check first that nothing off-board calls port 4001.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The infotainment firmware's API listens on localhost by default
- [x] #2 INFOTAINMENT_API_ON_ALL_INTERFACES=true in .env.exs restores listening on every interface
- [x] #3 Host runs are unchanged
<!-- AC:END -->
