---
id: TASK-94
title: Capture a camera of its own at full resolution and 35 fps
status: To Do
assignee: []
created_date: '2026-11-11 23:00'
labels:
  - vision
dependencies:
  - TASK-90
ordinal: 73000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`v4l2_capture`'s single mode converts each frame on one core. On the OVCS1 reference vehicle's VENTUNO Q, with the IMX477's 2028 × 1520 mode asked at 35 fps:

| Output | Delivered | Conversion per frame |
|---|---|---|
| `half`, 1014 × 760, denoise on | 34.9 fps | 17.1 ms |
| `full`, 2028 × 1520, denoise on | 16.6 fps | about 60 ms |
| `full`, denoise off | 21.3 fps | about 47 ms |

At 15 fps, before the denoise, `full` took 29.0 ms per frame. The OVCS1 HQ camera therefore runs `half` at 35 fps, which is all its detection and road segmentation use.

Full resolution at the camera's rate needs the conversion spread over several of the A78 cores (a 35 fps frame lasts 28.6 ms) and about 320 MB/s of RGB crossing the Port, which is not measured. Options to weigh in the design: splitting the frame into row bands converted by threads, with the demosaic and denoise rows overlapping at the bands' edges; sending the models' input at `half` and full resolution only as JPEG for viewing and recording; sharing the frames through memory rather than the Port.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 A camera of its own delivers `full` 2028 × 1520 colour frames at 35 fps on the VENTUNO Q, denoise on
- [ ] #2 The stereo pair's rate and the detection's rate are unchanged while it runs
- [ ] #3 The per-frame conversion time and the CPU it uses are recorded in `docs/vision/performance.md`
<!-- AC:END -->
