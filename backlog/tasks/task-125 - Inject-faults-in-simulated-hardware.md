---
id: TASK-125
title: Inject faults in simulated hardware
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
  - safety
dependencies:
  - TASK-124
ordinal: 85000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Scenario steps that inject a fault at the CAN boundary: a simulated component goes silent or reports a fault status; a frame is dropped, delayed or corrupted (bad counter or checksum); a GUI simulator disconnects. Each safety mechanism the VMS has gets a scenario asserting its safe reaction.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each fault kind is a scenario step, tested
- [ ] #2 Scenarios cover a silent generic controller (`FAILURE` latched) and a stale ROS command (throttle zeroed)
<!-- AC:END -->
