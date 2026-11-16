---
id: TASK-173
title: Compile a segmentation model for the OVCS Mini's 1152x576 band
status: In Progress
assignee:
  - '@claude'
created_date: '2026-11-15T17:42:00Z'
updated_date: '2026-11-15T20:40:00Z'
labels:
  - vision
dependencies:
  - TASK-169
ordinal: 118000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
STDC1 from Hailo's model zoo takes 1024x1920: the Mini's 1152x576 band is enlarged to it, and the HEF parks its skip connections in the host's RAM, about 56 MB over PCIe a frame (profile: 1.83 GB/s in, 1.59 GB/s out at 59.9 fps). On the Pi 5 that traffic slows every memory-bound process: at one frame in three, depth falls from 19.8 to 12 pairs a second. A model compiled at the band's size, 576x1152, removes the enlargement and most of that traffic.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 The model zoo's ONNX is rewritten for a 576x1152 input, reproducibly
- [x] #2 A HEF of it is compiled with the Dataflow Compiler v3.34.0, the one HailoRT 4.24.0 runs, calibrated on the Mini's camera frames
- [x] #3 Its classes agree with the float model's on a road scene, road IoU at least 0.95
- [ ] #4 On the Mini, with detection on every frame and segmentation on every third, the stereo keeps at least 18 pairs a second
<!-- AC:END -->

## Implementation Plan

<!-- SECTION:PLAN:BEGIN -->
Rewrite the simplified ONNX's input, output and Resize sizes for 576x1152 (scripts/hailo/resize_onnx.py), compile with the model zoo v2.20.0 model script, DFC 3.34.0 (scripts/hailo/compile_hef.py). Model: DDRNet-23-slim, model zoo v2.20.0 (MIT code, 76.3 hardware mIoU, about 17 MB over PCIe a frame at 1024x2048 against STDC1's 56), its argmax on the 1/8 scores, one class id per 8x8 cell. Compared on the Mini against STDC1 at 576x1152 (47 ms a frame alone, 55 beside detection) and the zoo's 1024x1920 STDC1 (87 ms): DDRNet at 576x1152 takes 26 ms alone, 31 beside detection. Rejected: segmenting fewer frames only; zero-copy HailoRT I/O alone (identical results, 13 ms less CPU a frame, no change on the board at 30 fps). The cameras run at 25 frames a second: at 30 the Pi 5's memory bandwidth no longer keeps up once segmentation runs.
<!-- SECTION:PLAN:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
On a Cityscapes street image: the 576x1152 float model agrees with the 1024x2048 one on 94.5% of the pixels (road IoU 0.98); the HEF on the Mini agrees with the float model on 98.8% of the cells (road IoU 0.99). Calibrated on 64 indoor frames of the Mini; outdoor frames would suit the scenes better. The HEF is local: vehicles/ovcs_mini/models/README.md builds it. #4 held, at 25 pairs a second, while the ROS 2 exporter dropped its messages; publishing, the stereo keeps 16.4 (TASK-174).
<!-- SECTION:NOTES:END -->
