---
id: TASK-64
title: Capture OVCS1's stereo pair at 35 frames a second
status: Done
assignee:
  - '@claude'
created_date: '2026-11-11 10:00'
labels:
  - vision
dependencies:
  - TASK-63
ordinal: 59000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
OVCS1's cameras capture at 30 frames a second, which the IMX296 exceeds and which nx_stereo's faster Vulkan scans no longer need as a limit: on the Arduino VENTUNO Q a pair of OVCS1's stages takes 28 ms (`mix vision_core.board_bench`, median of 40), down from 30.8 ms.

Measured live at 728x544: the depth rate follows the cameras up to about 34.5 Hz and stays there at 40 and 60 frames a second, the GPU busy all the time and the extra pairs dropped. Matching at a smaller size would go further (576x432: 19.5 ms a pair) but coarsens the depth.

Chosen: keep matching at 728x544 and capture at 35 frames a second, nx_stereo pinned at the change that makes it fast enough.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 OVCS pins nx_stereo at its main with the faster Vulkan scans, and vision_core's suite passes with it
- [x] #2 `Ovcs1.Vision.Composer` captures at 35 frames a second
- [x] #3 On the VENTUNO Q, OVCS1's live depth runs at about 34.5 Hz, matching at 728x544
- [x] #4 The vision guides give OVCS1's new rate and measurements
<!-- AC:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
nx_stereo's disparity stage gained `band`, `margin` and `fine_census` settings. `VisionCore.Stereo.Stage.Disparity` passed its whole state back as options when a stage restarts, as a calibration reload does, so the restart refused them as unknown settings; it now passes only the settings it declares, and nx_stereo keeps its defaults for the others.

Live on the VENTUNO Q at 35 frames a second: 34.55 Hz depth (camera 35.05), the stereo segment busy 98%, CPU 16%, 343 pairs and 317 detections in 10 s. At 30 frames a second it was 29.97 Hz with the segment busy 85%.
<!-- SECTION:NOTES:END -->
