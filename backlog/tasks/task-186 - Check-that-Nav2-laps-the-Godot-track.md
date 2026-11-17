---
id: TASK-186
title: Check that Nav2 laps the Godot track
status: To Do
assignee: []
created_date: '2026-11-17 19:00'
labels:
  - simulator
  - nav2
dependencies:
  - TASK-185
ordinal: 126000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The end-to-end check of the perception and navigation stack: the OVCS Mini, in Godot, driven by Nav2 under `:ros` with the road-following goals of TASK-185, completes a lap of the track. Like the Gazebo drive check, it starts the stack, runs, and reports pass or fail from the simulator's ground truth: lap completed, time and distance off the road, the closest approach to an obstacle. TASK-124's scenarios can later run it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 One command starts the stack against Godot and reports whether the Mini completed a lap
- [ ] #2 It fails on any wheel off the road for longer than a threshold it states, and on a lap not completed within a time it states
- [ ] #3 The guide that covers the Godot simulator documents the check
<!-- AC:END -->
