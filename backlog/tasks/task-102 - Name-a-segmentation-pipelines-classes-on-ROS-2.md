---
id: TASK-102
title: Name a segmentation pipeline's classes on ROS 2
status: To Do
assignee: []
created_date: '2026-11-12 12:00'
labels:
  - vision
dependencies:
  - TASK-92
ordinal: 81000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A segmentation pipeline's label image on ROS 2 carries class ids that index its `:labels` option, which a vehicle can change; a consumer cannot learn that 0 is `road`. ROS's idiom is `vision_msgs/LabelInfo` (`class_map`, id to name) published transient-local beside the image. `ros2_zenoh` has no `LabelInfo` yet.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 `ros2_zenoh` encodes `vision_msgs/LabelInfo`, checked against golden bytes from rclpy
- [ ] #2 Each segmentation pipeline publishes its classes on `<prefix>/<name>/label_info`, transient-local
<!-- AC:END -->
