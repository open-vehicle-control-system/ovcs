---
id: TASK-169
title: Detect and segment on the OVCS Mini's left colour camera, on its Hailo-8
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T15:07:00Z'
updated_date: '2026-11-15T15:11:00Z'
labels:
  - vision
dependencies: []
ordinal: 116000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The OVCS Mini detects on the stereo pair's grey frames and does not segment. Its left colour camera (TASK-165) sends a 1152×648 JPEG at every frame. Detection should run on that colour image, and a road segmentation pipeline should run on it too, both on the Hailo-8, as OVCS1 runs both on its centre camera.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 A detection pipeline on a JPEG camera output gets the frame in colour (RGB), decoded by jpeg_codec with libjpeg-turbo
- [x] #2 A segmentation pipeline segments a JPEG camera output's frames
- [ ] #3 Detection and segmentation pipelines run together on one Hailo-8
- [ ] #4 A :hailo_segmenter component runs a Cityscapes HEF and publishes its labels and road clouds as the QNN segmenter does
- [ ] #5 The OVCS Mini detects and segments on its left colour camera; on the unit the stereo keeps 20 pairs a second and both pipelines' rates and the CPU are measured
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Approach (agreed):
1. Colour for the pipelines from the JPEG the camera already sends: jpeg_codec decodes a JPEG to RGB with libjpeg-turbo; a pipeline on a JPEG output gets colour (detection was given the luma, segmentation skipped the frame). Rejected for now: camera_capture sending a raw RGB output (TASK-170), costlier in the capture loop and through the Port, kept in case JPEG artefacts or decode time prove a problem.
2. One Hailo-8 for two networks: one Port opens the device once and serves the detection and the segmentation networks through HailoRT's scheduler; the one-pipeline claim on the device becomes a claim per network. Rejected: HailoRT's multi-process service in the Pi 5 system.
3. Segmentation model: Hailo model zoo v2.15 stdc1 (Cityscapes, 19 classes, 74.6 mIoU, 58 fps alone on the Hailo-8, 1024×1920 input), fetched by fetch-models; Cityscapes weights are non-commercial, as FFNet's.
PRs, in order: (1) colour from JPEG; (2) the shared Hailo Port; (3) a Hailo segmentation backend and :hailo_segmenter; (4) stdc1 in fetch-models; (5) the Mini's composer: detection and segmentation on {:camera, :left, :half_jpeg}; (6) measured on the Mini.
<!-- SECTION:PLAN:END -->
