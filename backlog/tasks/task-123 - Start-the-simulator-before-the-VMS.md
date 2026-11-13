---
id: TASK-123
title: Start the simulator before the VMS
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
  - cli
dependencies:
  - TASK-122
ordinal: 83000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`./ovcs run <vehicle> --simulate` starts the simulator runner first, waits for its ready line, then starts the VMS and the other BEAMs, so the VMS boots against hardware that already answers, as on the vehicle. Without `--simulate` nothing changes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 With `--simulate`, the VMS starts only after the runner is ready, and the run fails clearly if the runner never gets ready
- [ ] #2 The OVCS Mini boots to `vms_status` OK under `--simulate`
- [ ] #3 docs/running_hardware.md and the simulator docs describe the flag
<!-- AC:END -->
