---
id: TASK-138
title: Calibrate a camera of its own from the vision dashboard
status: To Do
assignee: []
created_date: '2026-11-13T18:40:00Z'
labels: []
dependencies: []
ordinal: 95000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Calibration page calibrates the stereo pair only. A camera of its own, such as OVCS1's center camera, is calibrated with cameracalibrator over ROS 2.

Design, agreed: each camera of its own is a calibrations resource, identified by its name. A session on it detects the board in the frames of the output the unit receives from it, keeps samples with the same coverage, solves its intrinsics and distortion with calibrateCamera, and an apply writes them to the camera's calibration store and has the ROS 2 exporter read its camera info again. Its pipelines take the calibration when they start, as after a COMMIT. Its pose relative to the stereo pair is a separate task.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 GET /api/calibrations lists each camera of its own
- [ ] #2 A session on a camera solves and applies its intrinsics
- [ ] #3 The Calibration page lets the user pick the stereo pair or a camera
- [ ] #4 No camera name appears outside vehicles/
- [ ] #5 The guides match
<!-- AC:END -->
