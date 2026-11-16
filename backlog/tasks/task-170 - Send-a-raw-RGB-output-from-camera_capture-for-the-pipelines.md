---
id: TASK-170
title: Send a raw RGB output from camera_capture for the pipelines
status: To Do
assignee: []
created_date: '2026-11-15T15:07:00Z'
labels:
  - vision
dependencies: []
ordinal: 117000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
An alternative to decoding the JPEG of a libcamera camera of its own (TASK-169): camera_capture converts the ISP colour stream to RGB, shrunk on the CPU to the size the models need, and sends it as a raw output, as v4l2_capture does for OVCS1's centre camera. No JPEG artefacts in the models' input and no decode, at the cost of a YUV to RGB conversion in the capture loop and raw frames through the Port. Worth doing if the decode's time or the JPEG's artefacts show in the pipelines' rate or results on the Mini.
<!-- SECTION:DESCRIPTION:END -->
