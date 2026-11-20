---
id: TASK-185
title: Follow the road with a goal ahead of the vehicle
status: To Do
assignee: []
created_date: '2026-11-17 19:00'
labels:
  - nav2
  - ros
dependencies:
  - TASK-184
  - TASK-181
ordinal: 125000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Nav2 drives to a goal; it does not choose one. The Mini's costmaps live in `odom` only, with no map of the track, so nothing sets goals around it. A node keeps a goal a few metres ahead of the vehicle at the road's centre, from the road cloud, and moves it as the vehicle advances, so Nav2 follows the road with the planner and controller it already runs.

The distance ahead and the update rate are parameters. With no road ahead, the node cancels the goal and the vehicle stops.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The node places its goal on the road's centre at the set distance ahead, tested on recorded road clouds
- [ ] #2 With no road ahead, it cancels the goal and the vehicle stops
- [ ] #3 Against Godot, the Mini follows a curved section of the track without leaving the road
<!-- AC:END -->
