---
id: TASK-71
title: Judge the cameras' brightness and the depth on the unit
status: Done
assignee:
  - '@claude'
created_date: '2026-11-11 19:00'
labels:
  - vision
dependencies:
  - TASK-70
ordinal: 66000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The pair checks say when the cameras disagree on timing, rows or focus, but not when one sees through a hazy or dirty lens, and nothing says when the unit drops pairs because the stereo work outlasts a frame, or when the scene is nearer than the disparity range measures, where the depth is matched wrongly.

Chosen: nx_stereo's sharpness sums already hold each image's grey, so `NxStereo.Diagnostics.brightness/1` reads its mean, and `PairCheck` adds a `brightness` check pointing at the brighter camera. `VisionCore.Stereo.DepthCheck` judges a status window's `rate`, the share of the slower camera's pairs that do not become depth, and its `range`, the share of the last pair's matched pixels in the nearest 15% of the disparity range, sampled one pixel in 8 along each axis on the CPU once a tick. Its checks have the pair checks' shape, pointing at no camera. The status snapshot and channel carry them as `depth`; the dashboard badges and rings the depth preview and shows their figures under it.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 `PairCheck` judges brightness, pointing a warning at the brighter camera past 20% brighter
- [x] #2 `DepthCheck` judges dropped pairs past 5% and a scene too near past 15% of the matches in the nearest band, with named thresholds and issue codes
- [x] #3 The status snapshot and channel carry the depth checks, documented in the API guide with every issue code
- [x] #4 The dashboard shows the brightness check between the cameras, and the depth checks' figures and badges on the depth preview
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
On the Arduino VENTUNO Q at 35 fps the unit drops 3% of the pairs, and the right image reads 12% brighter than the left. The nearest band starts at 1.38 m with 128 disparities at the working width; the 15% threshold for a scene too near is to be confirmed against scenes kept clear of that range.
<!-- SECTION:NOTES:END -->
