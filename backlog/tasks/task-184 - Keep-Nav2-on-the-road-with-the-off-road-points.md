---
id: TASK-184
title: Keep Nav2 on the road with the off-road points
status: To Do
assignee: []
created_date: '2026-11-17 19:00'
labels:
  - nav2
  - vision
dependencies:
  - TASK-183
ordinal: 124000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The OVCS Mini's costmaps mark obstacles from `/stereo/points`, `/scan` and the rangefinders, all above `min_obstacle_height` 0.12 m. A track's edge has no height: grass, a painted line or a kerb lower than that is free space to Nav2, so the planner and MPPI cut across it.

Mark the segmentation pipeline's `<name>/off_road/points` in the Mini's local and global costmaps as a ground-level source, with no minimum height, and clear it with `<name>/road/points`, so the planned path and the controller keep to the road. TASK-108 leaves this wiring out of its scope.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Both costmaps mark off-road points at ground level and clear them with road points
- [ ] #2 Obstacles from the stereo cloud, the lidar and the rangefinders are marked as before
- [ ] #3 Against Godot, a goal across the track's grass yields a path that stays on the road, or none
<!-- AC:END -->
