---
id: TASK-98
title: Harden the camera calibration service and pin reprojection edge cases
status: To Do
assignee: []
created_date: '2026-11-12 08:45'
labels:
  - vision
dependencies:
  - TASK-91
ordinal: 77000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Gaps left by TASK-91's camera source: `SetCameraInfoServer` stores a calibration committed over ROS 2 without checking its distortion model or size, so a bad commit is found only at the next start; a few edge cases of the frame matching and the reprojection have no test.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A `set_camera_info` request with an unsupported distortion model or a size the camera does not capture is refused with `success: false` and nothing is written
- [ ] #2 A test pins a frame matched with a pair exactly at the capture-time tolerance, and one just past it
- [ ] #3 A test pins `plumb_bob`'s re-distortion check returning `nil` under strong tangential distortion
- [ ] #4 A camera-source detection published for a frame without a `frame_id` uses the camera's
<!-- AC:END -->
