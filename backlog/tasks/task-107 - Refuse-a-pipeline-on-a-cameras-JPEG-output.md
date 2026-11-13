---
id: TASK-107
title: Refuse a pipeline on a camera's JPEG output
status: To Do
assignee: []
created_date: '2026-11-12 19:00'
labels:
  - vision
dependencies:
  - TASK-94
ordinal: 86000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A camera's outputs can be JPEG (`format: :jpeg`). A detection or segmentation pipeline, or the pose capture, pointed at such an output is not refused: detection decodes only its luma, segmentation logs colourless frames and skips them, and the pose capture writes nothing.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A pipeline or the pose capture whose source names a JPEG output fails at start, naming the output and its format
<!-- AC:END -->
