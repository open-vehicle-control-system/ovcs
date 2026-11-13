---
id: TASK-137
title: Calibrate the stereo cameras from the vision dashboard, on the API rules
status: In Progress
assignee:
  - '@loic'
created_date: '2026-11-13T18:40:00Z'
labels: []
dependencies: []
ordinal: 94000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PR 265 calibrates the stereo pair on the unit, from the dashboard. Rebased on main, its API predates the HTTP API rules and names one target, the stereo pair.

Design, agreed: a calibrations collection, one resource per calibratable target, the stereo pair (its prefix) and each camera of its own (its name): GET /api/calibrations and GET /api/calibrations/:id. A session names its target as its calibration relationship; one session runs at a time on the unit. Solve, apply, cancel and reset stay created action resources, a reset naming its target. Apply answers 202 with the session applying, its outcome on the calibration channel; CODE_STYLING.md's status list gains 202 for work that goes on after the answer. The channel takes no write.

cameracalibrator's COMMIT keeps main's path through VisionCore.Ros2.Services.SetCameraInfoServer; the dashboard commits through VisionCore.Stereo.Calibration, and both have the ROS 2 exporter read its camera info again.

Options considered: keeping the stereo routes and adding a parallel set for cameras (two sets of routes for one thing); an apply that holds the request until the unit took the calibration (a request of several seconds).
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 The calibration routes follow CODE_STYLING.md's HTTP APIs section, with a controller test per refusal
- [ ] #2 GET /api/calibrations lists the stereo pair's calibration; GET /api/calibrations/:id reads it
- [ ] #3 A session, a reset name their target; apply answers 202
- [ ] #4 CODE_STYLING.md lists 202
- [ ] #5 The dashboard's Calibration page calibrates the stereo pair on a unit
- [ ] #6 The guides match
<!-- AC:END -->
