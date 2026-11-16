---
id: TASK-174
title: Lower what the vision unit's ROS 2 exporter costs the OVCS Mini
status: To Do
assignee: []
created_date: '2026-11-15T19:41:00Z'
labels:
  - vision
dependencies:
  - TASK-169
ordinal: 118000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
With a ROS 2 clock on the network, the Zenoh exporter publishes every matched pair's disparity, depth and points, the rectified image and the left camera's JPEG. On the Mini, with detection on every frame and segmentation on every third, that takes depth from 20.8 to 16.4 pairs a second and the BEAM from 62 to 99 % of a core: the Pi 5 is memory-bound, and every byte moved slows the cameras and the depth.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Each ROS 2 topic's cost on the Mini, in CPU and depth pairs a second, is measured
- [ ] #2 The Mini's composer publishes what its consumers need, at the rates they need, so the stereo keeps 20 pairs a second with detection on every frame and segmentation on every third
<!-- AC:END -->
