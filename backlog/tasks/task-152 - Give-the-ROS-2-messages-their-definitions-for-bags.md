---
id: TASK-152
title: Give the ROS 2 messages their definitions for bags
status: In Progress
assignee: []
created_date: '2026-11-14T19:13:00Z'
labels:
  - ros2
dependencies: []
ordinal: 105000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PR 1 of the ROS 2 bag exporter (TASK-151 to TASK-156, design in TASK-151): msg_definition/0 and dependencies/0 on the published message modules, Ros2Zenoh.definition/1 in the ros2msg schema format rosbag2 writes.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each published message module's msg_definition/0 equals ROS 2 Lyrical's .msg text
- [ ] #2 Ros2Zenoh.definition/1 lists each dependency once, depth-first, as rosbag2 does
<!-- AC:END -->
