---
id: TASK-179
title: Wait for the recorder between the saved pose test's two commits
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-16T21:28:00Z'
labels:
  - vision
  - tests
dependencies: []
ordinal: 120000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
VisionApiWeb.SavedCalibrationControllerTest's "puts a saved pose in use" commits two poses and waits for VisionCore.Calibration.Recorder once, after both. The recorder saves the pose in use when it takes a change, not the pose the change announced: one that reaches the first change after the second commit reads the second pose twice, and the library keeps one entry. It failed vision/api on #394's CI run.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The test waits for the recorder after each commit
- [x] #2 With the recorder held while both commits are made, the old test fails as in CI
<!-- AC:END -->
