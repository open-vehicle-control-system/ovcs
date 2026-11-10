---
id: TASK-60
title: OVCS1 depth at 30 pairs a second with 8 paths
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-09 22:16'
updated_date: '2026-11-10 00:02'
labels: []
dependencies: []
ordinal: 55000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
On the Arduino VENTUNO Q, OVCS1's default stages at 728x544 over 128 disparities, coarse to fine with 8 fine paths, keep up with the cameras' 30 frames a second, detection running. Measured 2026-11-09: 38.1 ms a pair (26/s) with 8 fine and 3 coarse paths; 31.6 ms with 3 and 3.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 One pair of the default stages with paths: 8 (coarse_paths 3 or more) takes at most 33 ms on the board, one pair at a time
- [x] #2 OVCS1's live unit with paths: 8 reports depth at 29.97 Hz with detection running
- [x] #3 Every board result equals EXLA's (0 pixels differ, matched counts equal) or, for a change of algorithm, the 2006 Middlebury half-size evaluation shows agreement with the current coarse-to-fine within 0.5 point and bad1 within 0.5 point
- [x] #4 nx_stereo and vision_core suites pass with --include vulkan, credo clean, every change committed and pushed with its measured gain
<!-- AC:END -->



## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
At least 30 pairs a second with 8 paths; once reached, keep improving (more margin, 8 coarse paths, a wider band, fewer holes). Profile every kernel on the board with the capture compiler and vkrun, attack the largest, measure each change on the board against EXLA, commit and push it with its gain.
1. Small kernels with poor throughput: band_base (0.7 ms), fine consistency (1.4 ms), coarse selection (2.4 ms), speckle filter (1.3 ms).
2. A third pyramid level: quarter-size full matching, half-size band, full-size band, if the Middlebury evaluation holds.
3. Overlap a pair's uploads and downloads with the GPU work of the previous one.
4. Fuse kernels that pass a full volume through memory (selection with consistency and median, scans with the cost computation).
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Board, 728x544, 128 disparities, coarse 3 / fine 8 paths, detection on: live depth 29.97 Hz over a minute (12 samples), 300 stereo pairs and 300 detections in 10 s, CPU 13-21%, stereo segment busy 93% of the frame time. One pair 31 to 33 ms (was 38.1); 3/3 27 to 30 ms. Every change equal to EXLA (0/396032 pixels differ). nx_stereo: packed-byte barrel in the band scans (scans 9.4 -> 8.0 ms), 6-bit band costs (fine block 16.3 -> 15.6 ms), coarse selection unrolled with direct reads (2.11 -> 0.98 ms), 3-path selection inside the vertical scan (2.21 -> 1.81 ms); earlier: consistency shared row, band bases per coarse pixel, OVCS speckle 4 px a thread. The fine block is now bound by memory traffic (~18 GB/s of a ~19 GB/s copy ceiling).
<!-- SECTION:NOTES:END -->
