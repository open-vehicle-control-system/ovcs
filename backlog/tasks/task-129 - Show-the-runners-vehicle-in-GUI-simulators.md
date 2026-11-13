---
id: TASK-129
title: Show the runner's vehicle in GUI simulators
status: To Do
assignee: []
created_date: '2026-11-13 14:00'
labels:
  - simulator
  - vision
dependencies:
  - TASK-122
  - TASK-128
ordinal: 89000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The simulator link (TCP, length-prefixed JSON header and binary body, from the `feat/simulator-godot` branch) in pose mode: the runner sends the pose every tick, and the GUI simulator returns its camera images, which the ROS bridge republishes as `CompressedImage` for vision. The GUI never moves the car. Godot and CARLA clients follow in their own repository.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The link protocol is documented and tested, including malformed and oversized messages
- [ ] #2 A disconnected GUI simulator does not stop the runner
- [ ] #3 Camera images reach ROS topics the vision pipeline reads
<!-- AC:END -->
