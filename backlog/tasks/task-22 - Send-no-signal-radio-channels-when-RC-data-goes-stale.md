---
id: TASK-22
title: Send no-signal radio channels when RC data goes stale
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
updated_date: '2026-11-08 11:10'
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
The bridge stamps RC_CHANNELS_OVERRIDE and sends 0 on every channel once it is stale. Test the emitter wiring, not only the pure builder.
<!-- SECTION:DESCRIPTION:END -->
