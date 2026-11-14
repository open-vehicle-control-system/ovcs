---
id: TASK-154
title: Record the vision unit's ROS 2 messages with BagExporter
status: To Do
assignee: []
created_date: '2026-11-14T19:13:00Z'
labels:
  - vision
  - ros2
dependencies: []
ordinal: 107000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
PR 3 of the ROS 2 bag exporter (TASK-151 to TASK-156, design in TASK-151): shared builders with a stamp function and uncompressed stereo images, the runner's queued delivery with counted drops, presets built from the configuration, clock choice, writer process, metadata.yaml.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A preset builds only what it records
- [ ] #2 No value is dropped before the writer without being counted
- [ ] #3 The since-start clock stamps log times and header stamps alike
<!-- AC:END -->
