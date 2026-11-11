---
id: TASK-93
title: Run OVCS1's detection and road segmentation on its HQ camera
status: To Do
assignee: []
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies:
  - TASK-90
  - TASK-91
  - TASK-92
parent_task_id: TASK-87
ordinal: 72000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Step 6 of TASK-87: the OVCS1 reference vehicle's composer declares the HQ camera and runs detection and road segmentation on it, its stereo pair computing depth only. The detection model is chosen by measuring both pipelines' rates on the NPU, a smaller YOLOX first. See TASK-87's Design.
<!-- SECTION:DESCRIPTION:END -->
