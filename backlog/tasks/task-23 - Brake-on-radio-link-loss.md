---
id: TASK-23
title: Brake on radio link loss
status: To Do
assignee: []
created_date: '2026-11-08 10:42'
labels:
  - P23
  - ovcs
milestone: m-3
dependencies:
  - TASK-21
  - TASK-22
ordinal: 23000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On no-signal or a missing frame: request the vehicle's link-loss braking (composer option, negative throttle on OVCS1 and OVCS Mini). A run of out-of-range readings counts as link loss. Set allowed_missing_frames_period explicitly on 0x2A0/0x2A1.
<!-- SECTION:DESCRIPTION:END -->
