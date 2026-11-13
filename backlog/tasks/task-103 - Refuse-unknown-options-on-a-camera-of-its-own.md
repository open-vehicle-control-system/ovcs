---
id: TASK-103
title: Refuse unknown options on a camera of its own
status: To Do
assignee: []
created_date: '2026-11-12 12:30'
labels:
  - vision
dependencies:
  - TASK-90
ordinal: 82000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The `:camera` component and its drivers (`VisionCore.Camera.V4L2Single`) accept any key, so a misspelt option in a vehicle's composer (`pose_path:` for `pose:`) is ignored without a word and the camera runs without what it names. The detectors and segmenters already refuse unknown options at start.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A `:camera` component with an option neither the unit nor its driver takes fails at start with a message naming it
<!-- AC:END -->
