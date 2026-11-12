---
id: TASK-101
title: Refuse unknown detection pipelines in the ROS 2 exporter
status: To Do
assignee: []
created_date: '2026-11-12 12:00'
labels:
  - vision
dependencies: []
ordinal: 80000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`VisionCore.Ros2.Exporter`'s `check/1` refuses a `segmentation: pipelines:` or `cameras: names:` entry the configuration does not have, but drops an unknown `detections: pipelines:` name silently, so a typo in a vehicle's exporter options publishes nothing without a word.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 An unknown name in `detections: pipelines:` stops the exporter at start with a message naming it, as `segmentation:` does
<!-- AC:END -->
