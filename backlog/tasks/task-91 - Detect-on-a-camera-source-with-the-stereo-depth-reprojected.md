---
id: TASK-91
title: Detect on a camera source with the stereo depth reprojected
status: To Do
assignee: []
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies:
  - TASK-89
parent_task_id: TASK-87
ordinal: 70000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 4 of TASK-87: a camera as a pipeline's source, with its calibration and pose relative to the rectified left frame, the stereo depth reprojected into its image, detections without a distance published as `Detection2DArray`, its preview and its ROS 2 image and `camera_info`. Developed on the host with a USB camera; runs on the VENTUNO Q once TASK-90 lands. See TASK-87's Design.
<!-- SECTION:DESCRIPTION:END -->
