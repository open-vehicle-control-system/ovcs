---
id: TASK-23
title: Brake on radio link loss
status: To Do
assignee: []
created_date: '2026-11-08 10:42'
updated_date: '2026-11-08 11:33'
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
The VMS detects link loss itself: the radio counter stops changing (reusing RosCommand.Freshness), the frame stops arriving, or out-of-range readings keep coming. On link loss it requests the vehicle's link-loss braking (composer option, a negative throttle on OVCS1 and OVCS Mini). Set allowed_missing_frames_period explicitly on 0x2A0/0x2A1. No safety decision relies on the bridge's own checks.
<!-- SECTION:DESCRIPTION:END -->
