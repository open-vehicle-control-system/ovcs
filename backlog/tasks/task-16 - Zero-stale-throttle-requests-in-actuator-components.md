---
id: TASK-16
title: Zero stale throttle requests in actuator components
status: To Do
assignee: []
created_date: '2026-11-08 10:41'
labels:
  - P16
  - ovcs
milestone: m-2
dependencies:
  - TASK-9
ordinal: 16000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Inverter, iBooster and VESC record when requested_throttle last arrived and treat an old value as zero, reusing RosCommand.Freshness.
<!-- SECTION:DESCRIPTION:END -->
