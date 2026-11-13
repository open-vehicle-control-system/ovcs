---
id: TASK-124
title: Run scenarios against the simulated vehicle
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
dependencies:
  - TASK-123
ordinal: 84000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A scenario is a list of timed steps: operator actions (ignition key, radio channels, a ROS command, the VMS reset through `POST /api/actions`) and assertions with a timeout on what the VMS sends on CAN (`vms_status` status and ready to drive, actuator requests) and on the motion. The ignition key and the radio become scenario inputs instead of scripts inside simulated components. `./ovcs simulate <vehicle> <scenario>` runs one headless and exits non-zero on the first failed assertion, naming it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A scenario boots the OVCS Mini, puts it under `:ros` and drives it a set distance
- [ ] #2 A scenario recovers a latched `FAILURE` with the operator's reset
- [ ] #3 A failed assertion names the step, the expected and the observed value
<!-- AC:END -->
